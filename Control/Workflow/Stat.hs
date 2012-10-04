{-# OPTIONS  -XUndecidableInstances
             -XDeriveDataTypeable
             -XTypeSynonymInstances
             -XExistentialQuantification
             -XMultiParamTypeClasses
             -XFlexibleInstances
             -XOverloadedStrings
             -XRecordWildCards
             -XScopedTypeVariables
          #-}
module Control.Workflow.Stat where

import Data.TCache
import Data.TCache.Defs

import System.IO
import System.IO.Unsafe
import Data.Typeable
import qualified Data.Map as M
import Control.Concurrent(ThreadId)
import Control.Concurrent.STM(TVar, newTVarIO)
import Data.IORef
import Data.RefSerialize
import Control.Workflow.IDynamic

import Control.Monad(replicateM)

import qualified Data.ByteString.Lazy.Char8 as B hiding (index)
import  Data.ByteString.Char8(findSubstring)
import Control.Workflow.IDynamic
import Control.Concurrent
import Control.Exception(catch,bracket,SomeException)
import System.IO.Error

import System.Directory
import Data.List
import Control.Monad

--import Debug.Trace
--(!>) =  flip trace

data WF  s m l = WF { st :: s -> m (s,l) }


data Stat =  Running (M.Map String (String, (Maybe ThreadId)))
          | Stat{ self      :: DBRef Stat
                , wfName    :: String
                , state     :: Int
                , recover   :: Bool
                , timeout   :: Maybe Integer
                , lastActive:: Integer
                , context   :: (Context, B.ByteString)
                , references:: [(Int,(IDynamic,Bool))]
                , versions  :: [IDynamic]
                }
           deriving (Typeable)

stat0 = Stat{ wfName="", state=0,  recover=False, versions = []
            , lastActive=0,   timeout= Nothing
            , context = (unsafePerformIO newContext,"")
            , references= []
            , self=getDBRef ""}

statPrefix1= "Stat"
statPrefix= statPrefix1 ++"/"

header Stat{..}= do
     insertString "\r\n"
     insertString $ B.pack statPrefix1
     showpText wfName
     showpText state
     insertChar('(')
     showp timeout
     insertChar(')')
     showp lastActive
--     showp $ markAsWritten references
--     where
--     markAsWritten = map (\(n,(r,_)) -> (n,(r,True)))

getHeader= do
        symbol statPrefix1
        wfName <- readp
        state <- readp
        timeout <- parens readp
        lastActive <- readp
--        references <- readp
        c   <- getRContext
        return  (wfName, state, timeout, lastActive,[],c)

lenLen= 50


instance  Serialize Stat where
    showp (Running map)= do
          insertString $ B.pack "Running"
          showp $ Prelude.map (\(k,(w,_))  -> (k,w)) $ M.toList map


    showp  stat@Stat{..} = do
              s <- showps $ Prelude.reverse versions
              let l= show (B.length s + lenLen) ++" "++ show state
              insertString . B.pack $ l ++ take (fromIntegral lenLen - length l - 2) (repeat ' ')++ "\r\n"
              insertString s
              header stat

    readp = choice [rStat, rWorkflows] <?> "on reading Workflow State" where
        rStat= do
              integer
              integer
              versions   <- readp
              (wfName, state, timeout, lastActive,references,cont) <- getHeader


              let self= getDBRef $ keyResource stat0{wfName= wfName}
              return $ Stat self wfName   state   True  timeout lastActive
                            cont references versions


        rWorkflows= do
               symbol "Running"
               list <- readp
               return $ Running $ M.fromList $ Prelude.map(\(k,w)-> (k,(w,Nothing))) list




-- | Return the unique name of a workflow with a parameter (executed with exec or start)
keyWF :: Indexable a => String -> a -> String
keyWF wn x= wn ++ "/" ++ key x


data WFRef a= WFRef !Int !(DBRef Stat)  deriving (Typeable, Show)

instance Indexable (WFRef a) where
    key (WFRef n ref)= keyObjDBRef ref++('#':show n)


--instance  Serialize a  => Serializable a  where
--  serialize = runW . showp
--  deserialize = runR readp

pathWFlows=  (defPath (1:: Int)) ++ "Workflow/"
stFName st = pathWFlows ++ keyResource st
Persist fr fw fd = defaultPersist

--nheader= "/header"
--nlog= "/log"
--ncontext= "/context"


instance IResource Stat where

  keyResource s@Stat{wfName=name}=  statPrefix ++ name
  keyResource (Running _)= keyRunning


  readResourceByKey k = fr (pathWFlows ++ k)
                        >>= return . fmap ( runR  readp)

  delResource st= fd  (stFName st) -- removeFile (stFName st)  `catch`\(e :: IOError) -> return ()

  writeResource runn@(Running _)=  B.writeFile (stFName runn)  . runW $ showp runn

--
  writeResource stat@Stat{..}
   | recover = return ()

   | refs <- filter (\(n,(_,written))-> not written) references,
     not $ null refs= do
          let n= stFName stat
          st <- readResource  stat               -- !> ("WRITING references " ++ wfName )
          safe n $ \h ->  do
            let elems= case st of
                  Just s@Stat{state=states,versions= verss} -> verss ++  (reverse $ take (state  - states) versions )
                  Nothing -> reverse versions

            let versions'= substs elems refs
            hSeek h AbsoluteSeek 0
            B.hPut h  $ runWC context $ showp  $ stat{versions=reverse versions'}

            writeContext h
            hTell h >>= hSetFileSize h

   | otherwise= do
      let n= stFName stat
      safe n $ \h -> do
       (seek,written) <- getWritten h
       writeLog seek written h


    where

    writeHeader h=  B.hPut h  $ runWC context $  header stat

    writeLog seek written h

        | written==0=do
            hSeek h AbsoluteSeek 0              -- !> ("WRITING complete " ++ wfName )
            B.hPut h  . runWC context . showp $ stat

            writeContext h
            hTell h >>= hSetFileSize h

        | otherwise= do
           hSeek h AbsoluteSeek 0                -- !> ("WRITING partial " ++ wfName )
           let s = runWC context $ insertString "\r\n" >> showpe written ( reverse $ take (state - written)   versions)
           let l= show (seek -3 + B.length s) ++" "++ show state
           B.hPut h . B.pack $ l ++ take (fromIntegral lenLen - length l - 2) (repeat ' ') ++ "\r\n"
           hSeek h AbsoluteSeek (fromIntegral seek  - 3)
           B.hPut h s
           writeHeader h
           writeContext h
           hTell h >>= hSetFileSize h

    subst elems (n,( x,_))=
      let
          tail' []= []
          tail' t = tail t
          (h,t)= splitAt n elems
      in  h ++ ( x:tail' t)

    substs elems xs= foldl subst elems  xs

    writeContext h=  B.hPut h $ showContext (fst context) True

    getWritten h= do
        size <- hFileSize h
        if size == 0 then return (0,0)
          else do
           s   <- B.hGetNonBlocking h   (fromIntegral lenLen)
           return $ runR ( return (,) `ap` readp `ap` readp) s
--                seek <- readp
--                written <- readp
--                )  s




    showpe _ []  = insertChar ']'
    showpe 0 (x:xs)  = do
          rshowp x
          showpe 1 xs
    showpe v (x:l)  = insertString "," >> rshowp x >> showpe v l



safe name f= bracket
     (openFile name ReadWriteMode)
     hClose
     f
   `Control.Exception.catch` (handler name (safe name f))
  where
  handler  name doagain e 
   | isDoesNotExistError e=do 
              createDirectoryIfMissing True $ Prelude.take (1+(Prelude.last $ Data.List.elemIndices '/' name)) name   --maybe the path does not exist
              doagain               


   | otherwise= if ("invalid" `isInfixOf` ioeGetErrorString e)
         then
            error  $ "writeResource: " ++ show e ++ " defPath and/or keyResource are not suitable for a file path"
         else do
            hPutStrLn stderr $ "defaultWriteResource:  " ++ show e ++  " in file: " ++ name ++ " retrying"
            doagain


hReadFile h = do
  s <-  hFileSize h
  if s == 0 then return ""
            else  B.hGetNonBlocking h (fromIntegral s)


readHeader scont  h= do
     size <- hFileSize h
     if size==0 then return Nothing else do
       s <- B.hGetNonBlocking h (fromIntegral size)
       return . Just $ runR getHeader $ s `B.append` scont




keyRunning= "Running"




instance Serialize ThreadId where
  showp th= return () -- insertString . pack $ show th
  readp = {-(readp `asTypeOf` return ByteString) >>-} (return . unsafePerformIO .  forkIO $ return ())



-- | show the state changes along the workflow, that is, all the intermediate results
showHistory :: Stat -> B.ByteString
showHistory Stat {..}=  runW  sp
    where
    sp  = do
            insertString $ B.pack "Workflow name= "
            showp wfName
            insertString $ B.pack "\n"
            showElem  $ zip [1..]  versions
            c <- getWContext
            insertString $ showContext (fst c) True

--    showElem :: [(Int,IDynamic)] -> STW ()
    showElem [] = insertChar '\n'
    showElem ((n , dyn):es) = do
         insertString $ B.pack "Step "
         showp (n :: Int)
         insertString $ B.pack ": "
         showp1  dyn
         insertChar '\n'
         showElem es

showp1 (IDyn r)=
     case unsafePerformIO $ readIORef r of
      DRight x  -> showp x
      DLeft (s, _) -> insertString s



instance Indexable String where
  key= id

instance Indexable Int where
  key= show

instance Indexable Integer where
  key= show


instance Indexable () where
  key _= "void"

wFRefStr = "WFRef"

-- | default instances

instance (Show a, Read a )=> Serialize a where
  showp= showpText
  readp= readpText


instance  Serialize (WFRef a) where
  showp (WFRef n ref)= do
     insertString $ B.pack wFRefStr
     showp n
     showp $ keyObjDBRef ref

  readp= do
     symbol wFRefStr
     n <- readp
     k <- readp
     return . WFRef n $ getDBRef k



