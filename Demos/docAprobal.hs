{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables #-}
{-
  This program is  an example of simple workflow management. Once a document
   is created by the user, a workflow  controls two levels of approbal (boss and superboss)  trough
   messages to the presentation layer of the three different user roles.

   A document is created by the user "user", then is validated by two bosses and thwo super bosses.
   If any of the two dissapprobe, the document is sent to the user to modify it.

   This program can handle as many document workflows as you like simultaneously.

   Workflow patterns and queue communication primitives are used.

   The second level of approbal  has a timeout . The seralization of the document is
   trough the Serialize class of the RefSerialize package.

   approbed and dissapprobed documents are stored in their respective queues

   When te document title is modified, the workflow launches a new workflow with the new
   document and stops.



-}
import Control.Workflow

import Data.Persistent.Queue
import Control.Workflow.Patterns

import Data.Typeable
import System.Exit
import Data.List (find)
import Data.Maybe(fromJust)
import Control.Monad (when)
import Control.Concurrent ( forkIO)
import GHC.Conc ( atomically)
import Data.RefSerialize
import Data.TCache(syncCache)
import Data.ByteString.Lazy.Char8(pack)

import Data.Monoid


import Debug.Trace


(!>) a b= trace b a

data Document=Document{title :: String , text :: [String]} deriving (Read, Show,Eq,Typeable)

instance Indexable Document where
  key (Document t _)= "Doc#"++ t

instance Serialize Document where
    showp  (Document title  text)=  do
       insertString $ pack "Document"
       showp title
       rshowp text


    readp= do
       symbol  "Document"
       title <- readp
       text  <- rreadp
       return $ Document title text

--instance Binary Document where
--   put (Document title  text)=  do
--      put title
--      put text
--   get= do
--     title <- get
--     text  <- get
--     return $ Document title text



user= "user"

approved = "approved"
rejected = "rejected"

quser :: String -> RefQueue (WFRef Document)
quser user= getQRef user

qdoc :: String -> RefQueue Document
qdoc doc  = getQRef doc

qdocApprobal :: String -> RefQueue Bool
qdocApprobal doc  = getQRef doc


qapproved ::  RefQueue  Document
qapproved = getQRef approved

qrejected :: RefQueue  Document
qrejected = getQRef rejected




main = do
   -- restart the interrupted document approbal workflows (if necessary)

   restartWorkflows [("docApprobal",docApprobal)]

   putStrLn "\nThis program is  an example of simple workflow management; once a document is created a workflow thread controls the flow o mail messages to three different users that approbe or disapprobe and modify the document"
   putStrLn "A document is created by the user, then is validated by the boss and the super boss. If any of the two dissapprobe, the document is sent to the user to modify it."
   putStrLn "\n please login as:\n 1- user\n 2- boss1\n 3- boos2\n 4- super boss1\n 5- super boss2\n\n Enter the number"

   n <- getLine
   case n of
     "1" -> userMenu
     "2" -> aprobal "boss1"
     "3" -> aprobal "boss2"
     "4" -> aprobal "superboss1"
     "5" -> aprobal "superboss2"



bosses= ["boss1", "boss2"]
superbosses= ["superboss1", "superboss2"]

-- used by sumUp to sum the boolean "votes"
-- in this case OR is used
instance Monoid Bool where
  mappend = (||)
  mempty= False

{-
 the approbal procedure of a document below.
First the document reference is sent to a list of bosses trough a queue.
they return a boolean trough a  return queue ( askUser)
the booleans are summed up according with a monoid instance by sumUp

in checkValidated, if the resullt is false, the correctWF workflow is executed
If the result is True, the pipeline continues to the next stage

the next stage is the same process with a new list of users (superbosses).
This time, there is a timeout of one day That time counts even if the program is
not running. the result of the users that voted is summedup according with the
same monoid instance

in chechValidated1, if the result is true the document is added to the persistent list of approbed documents
if the result is false, the document is added to the persistent list of rejectec documents (checlkValidated1)

-}

docApprobal :: Document -> Workflow IO ()
docApprobal doc =  getWFRef >>= docApprobal1
  where
  -- using a reference instead of the doc itself
  docApprobal1 rdoc=
    return True >>=
    log "requesting approbal from bosses" >>=
    sumUp 0 (map(askUser (title doc) rdoc) bosses )  >>=
    checkValidated >>=
    log "requesting approbal from superbosses or timeout" >>=
    sumUp (1*day) (map(askUser (title doc) rdoc) superbosses) >>=
    checkValidated1

    where
    sec= 1
    min= 60* sec
    hour= 60* min
    day= 24*hour
    askUser _   _    user False = return False
    askUser title rdoc user True  =  do
      step $ push (quser user) rdoc
      logWF ("wait for any response from the user: " ++ user)
      step . pop $ qdocApprobal title


    log txt x = logWF txt >> return x

    checkValidated :: Bool -> Workflow IO Bool
    checkValidated  val =
      case val of
        False -> correctWF (title doc) rdoc >> return False
                    !> "not validated. re-sent to the user for correction"
        _     -> return True


    checkValidated1 :: Bool -> Workflow IO ()
    checkValidated1 val = step $ do
      case  val of
        False -> push qrejected doc
        _     -> push qapproved doc

      -- because there may have been a timeout,
      -- the doc references may remain in the queue
      mapM_ (\u ->deleteElem (quser u) rdoc) superbosses




{- old code of docAprobal with no sumUp pattern
docApprobal :: Document -> Workflow IO ()
docApprobal doc= do
  logWF "message sent to the boss requesting approbal"
  step $ writeTQueue qboss doc

  -- wait for any response from the boss
  ap <- step $ readTQueue $ qdoc  doc
  case ap of
   False -> do logWF "not approved, sent to the user for correction"
               correctWF doc
   True ->  do
    logWF " approved, send a message to the superboss requesting approbal"
    step $ writeTQueue  qsuperboss  doc

    -- wait for any response from the superboss
    -- if no response from the superboss in 5 minutes, it is validated
    flag <- getTimeoutFlag $  5 * 60
    ap <- step . atomically $ readTQueueSTM (qdoc  doc)
                              `orElse`
                              waitUntilSTM flag >> return True
    case ap of
       False -> do logWF "not approved, sent to the user for correction"
                   correctWF doc
       True -> do
                logWF " approved, sent  to the list of approved documents"
                step $ writeTQueue  qapproved doc

-}

correctWF :: String -> WFRef Document -> Workflow IO ()
correctWF  title1 rdoc= do
    -- send a message to the user to correct the document
    step $ push  (quser user) rdoc
    -- wait for document edition
    doc' <- step $ pop (qdoc title1)
    if title1 /= title doc'
      -- if doc and new doc edited hace different document title,  then start a new workflow for this new document
      -- since a workflow is identified by the workflow name and the key of the starting data, this is a convenient thing.
      then  step $ exec "docApprobal" docApprobal  doc'
      -- else continue the current workflow by retryng the approbal process
      else docApprobal doc'


create = do
  separator
  doc <- readDoc
  putStrLn "The document has been sent to the boss.\nPlease wait for the approbal"
  forkIO $ exec "docApprobal"  docApprobal doc
  userMenu

userMenu= do
  separator
  putStrLn"\n\n1- Create document\n2- Documents to modify\n3- Approbed documents\n4- manage workflows\nany other- exit"
  n <- getLine
  case n of
     "1" -> create
     "2" -> modify
     "3" -> view
     "4" -> history
     _   -> syncCache >> exitSuccess

  userMenu



history=  do
  separator
  putStr "MANAGE WORKFLOWS\n"
  ks <- getWFKeys  "docApprobal"
  mapM (\(n,d) -> putStr (show n) >> putStr "-  " >> putStrLn d) $ zip [1..] ks
  putStr $ show $ length ks + 1
  putStrLn "-  back"
  putStrLn ""
  putStrLn " select  v[space] <number> to view the history or d[space]<number> to delete it"
  l <- getLine
  if length l /= 3 || (head l /= 'v' && head l /= 'd') then history else do
   let n= read $ drop 2 l
   let docproto=  Document{title=  ks !! (n-1), text=undefined}
   case head l of
      'v' -> do
               getWFHistory  "docApprobal" docproto >>= printHistory  .  fromJust
               history
      'd' -> do
               delWF "docApprobal" docproto
               history

      _ -> history

separator=    putStrLn "------------------------------------------------"


modify :: IO ()
modify= do
   separator
   empty  <-  isEmpty (quser user) :: IO Bool
   if empty then  putStrLn "no more documents to modify\nthanks, enter as  Boss for the  approbal"
      else do
       rdoc <- pick (quser user)
       putStrLn "Please correct this doc"
       Just doc <- atomically $ readWFRef rdoc
       print doc
       doc1 <- readDoc

      -- return $ diff doc1 doc
       atomically $ do
            popSTM  (quser user)
            pushSTM (qdoc $ title doc) doc1
       modify

diff (Document t xs) (Document _ ys)=
       Document t $  map (search ys) xs
       where
       search xs x= case  find (==x) xs of
                                 Just x' -> x'
                                 Nothing -> x


readDoc :: IO Document
readDoc = do
     putStrLn "please enter the title of the document"
     title1 <- getLine
     h <- getWFHistory "docApprobal" $  Document title1 undefined
     case h of
       Just  _ -> putStrLn "sorry document title already existent, try other" >> readDoc
       Nothing -> do
             putStrLn "please enter the text. "
             putStrLn "the edition will end wth a empty line "
             text <- readDoc1 [title1]
             return $ Document title1 text
             where
             readDoc1 text= do
                 line <- getLine
                 if line == "" then return text else readDoc1 $  text ++ [line]




view= do
   separator
   putStrLn "LIST OF APPROVED DOCUMENTS:"
   view1
   where
   view1= do
           empty <- isEmpty qapproved
           if empty then return () else do
           doc <- pop qapproved   :: IO Document
           print doc
           view1



aprobal who= do
 separator
 aprobalList
 putStrLn $ "thanks , press any key to exit, "++ who
 getLine
 syncCache
 return ()
 where
 aprobalList= do
     empty <- isEmpty  (quser who)
     if empty
         then   do
            putStrLn  "No more document to validate. Bye"
            return ()
         else do
             rdoc <- pick  (quser who)
             syncCache
             approbal1 rdoc
             aprobalList
 approbal1 :: WFRef Document -> IO ()
 approbal1 rdoc= do
       putStrLn $ "hi " ++ who ++", a new request for aprobal has arrived:"
       Just doc <- atomically $ readWFRef rdoc
       print doc
       putStrLn $  "Would you approbe this document? s/n"
       l <-    getLine
       if l/= "s" && l /= "n" then approbal1 rdoc else do
        let b= head l
        let res= if b == 's' then  True else  False
           -- send the message to the workflow
        atomically $ do
                popSTM   (quser who)
                pushSTM  (qdocApprobal  $ title doc)  res
        syncCache




