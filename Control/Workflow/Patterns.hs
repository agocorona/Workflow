{-# LANGUAGE   DeriveDataTypeable
             , ScopedTypeVariables
             , FlexibleContexts

              #-}
{-# OPTIONS -IControl/Workflow       #-}

{- | This module contains monadic combinators that express some workflow patterns.
see the docAprobal.hs example included in the package

Here  the constraint `DynSerializer w r a` is equivalent to  `Data.Refserialize a`
This version permits optimal (de)serialization if you store in the queue different versions of largue structures, for
example, documents.  You must  define the right RefSerialize instance however.
See an example in docAprobal.hs incuded in the paclkage.
Alternatively you can use  Data.Binary serlializatiion with Control.Workflow.Binary.Patterns

EXAMPLE:

This fragment below describes the approbal procedure of a document.
First the document reference is sent to a list of bosses trough a queue.
ithey return a boolean in a  return queue ( askUser)
the booleans are summed up according with a monoid instance (sumUp)

if the resullt is false, the correctWF workflow is executed
If the result is True, the pipeline continues to the next stage  (checkValidated)

the next stage is the same process with a new list of users (superbosses).
This time, there is a timeout of 7 days. the result of the users that voted is summed
up according with the same monoid instance

if the result is true the document is added to the persistent list of approbed documents
if the result is false, the document is added to the persistent list of rejectec documents (checlkValidated1)


@docApprobal :: Document -> Workflow IO ()
docApprobal doc =  `getWFRef` \>>= docApprobal1


docApprobal1 rdoc=
    return True \>>=
    log \"requesting approbal from bosses\" \>>=
    `sumUp` 0 (map (askUser doc rdoc) bosses)  \>>=
    checkValidated \>>=
    log \"requesting approbal from superbosses or timeout\"  \>>=
    `sumUp` (7*60*60*24) (map(askUser doc rdoc) superbosses) \>>=
    checkValidated1


askUser _ _ user False = return False
askUser doc rdoc user  True =  do
      `step` $ `push` (quser user) rdoc
      `logWF` ("wait for any response from the user: " ++ user)
      `step` . `pop` $ qdocApprobal (title doc)

log txt x = `logWF` txt >> return x

checkValidated :: Bool -> `Workflow` IO Bool
checkValidated  val =
      case val of
        False -> correctWF (title doc) rdoc >> return False
        _     -> return True


checkValidated1 :: Bool -> Workflow IO ()
checkValidated1 val = step $ do
      case  val of
        False -> `push` qrejected doc
        _     -> `push` qapproved doc
      mapM (\u ->deleteFromQueue (quser u) rdoc) superbosses@

-}

module Control.Workflow.Patterns(
-- * Low level combinators
split, merge, select,
-- * High level conbinators
vote, sumUp, Select(..)
) where
import Control.Concurrent.STM
import Data.Monoid
import Control.Concurrent.MonadIO
import qualified Control.Monad.CatchIO as CMC
import Control.Workflow.Stat
import Control.Workflow
import Data.Typeable
import Prelude hiding (catch)
import Control.Monad(when)
import Control.Exception.Extensible (Exception)
import Data.RefSerialize
import Control.Workflow.Stat
import Debug.Trace
import Data.TCache

a !> b = trace b a

data ActionWF a= ActionWF (WFRef(Maybe a))  (WFRef (String, Bool))

-- | spawn a list of independent workflows (the first argument) with a seed value (the second argument).
-- Their results are reduced by `merge` or `select`
split :: ( Typeable b
           , Serialize b
           , HasFork io
           , CMC.MonadCatchIO io)
          => [a -> Workflow io b] -> a  -> Workflow io [ActionWF b]
split actions a = mapM (\ac ->
     do
         mv <- newWFRef Nothing
         fork  (ac a >>= step . liftIO . atomically . writeWFRef mv . Just)
         r <- getWFRef
         return  $ ActionWF mv  r)

     actions



-- | wait for the results and apply the cond to produce a single output in the Workflow monad
merge :: ( MonadIO io
           , Typeable a
           , Typeable b
           , Serialize a, Serialize b)
           => ([a] -> io b) -> [ActionWF a] -> Workflow io b
merge  cond actions= mapM (\(ActionWF mv _) -> readWFRef1 mv ) actions >>= step . cond

readWFRef1 :: ( MonadIO io
              , Serialize a
              , Typeable a)
              => WFRef (Maybe a) -> io  a
readWFRef1 mv = liftIO . atomically $ do
      v <- readWFRef mv
      case v of
       Just(Just v)  -> return v
       Just Nothing  -> retry
       Nothing -> error $ "readWFRef1: workflow not found "++ show mv


data Select
            = Select
            | Discard
            | FinishDiscard
            | FinishSelect
            deriving(Typeable, Read, Show)

instance Exception Select

-- | select the outputs of the workflows produced by `split` constrained within a timeout.
-- The check filter, can select , discard or finish the entire computation before
-- the timeout is reached. When the computation finalizes, it stop all
-- the pending workflows and return the list of selected outputs
-- the timeout is in seconds and is no limited to Int values, so it can last for years.
--
-- This is necessary for the modelization of real-life institutional cycles such are political elections
-- timeout of 0 means no timeout.
select ::
         ( Serialize a
         , Serialize [a]
         , Typeable a
         , HasFork io
         , CMC.MonadCatchIO io)
         => Integer
         -> (a ->   io Select)
         -> [ActionWF a]
         -> Workflow io [a]
select timeout check actions=   do
 res  <- newMVar []
 flag <- getTimeoutFlag timeout
 parent <- myThreadId
 checks <- newEmptyMVar
 count <- newMVar 1
 let process = do
        let check'  (ActionWF ac _) =  do
               r <- readWFRef1 ac
               b <- check r
               case b of
                  Discard -> return ()
                  Select  -> addRes r
                  FinishDiscard -> do
                       throwTo parent FinishDiscard
                  FinishSelect -> do
                       addRes r
                       throwTo parent FinishDiscard

               n <- CMC.block $ do
                     n <- takeMVar count
                     putMVar count (n+1)
                     return n

               if ( n == length actions)
                     then throwTo parent FinishDiscard
                     else return ()

              `CMC.catch` (\(e :: Select) -> throwTo parent e)

        do
             ws <- mapM ( fork . check') actions
             putMVar checks  ws

        liftIO $ atomically $ do
           v <- readTVar flag -- wait fo timeout
           case v of
             False -> retry
             True  -> return ()
        throw FinishDiscard
        where

        addRes r=  CMC.block $ do
            l <- takeMVar  res
            putMVar  res $ r : l

 let killall  = do
       mapM_ (\(ActionWF _ th) -> killWFP th) actions
       ws <- readMVar checks
       liftIO $ mapM_ killThread ws

 stepControl $ CMC.catch   process -- (WF $ \s -> process >>= \ r -> return (s, r))
              (\(e :: Select)-> do
                 readMVar res
                 )
       `CMC.finally`   killall

killWFP r= liftIO $ do
    s <-  atomically $ do
              (s,_)<- readWFRef r >>= justify ("wfSelect " ++ show r)
              writeWFRef r (s, True)
              return s

    killWF  s ()

justify str Nothing = error str
justify _ (Just x) = return x

-- | spawn a list of workflows and reduces the results according with the comp parameter within a given timeout
--
-- @
--   vote timeout actions comp x=
--        split actions x >>= select timeout (const $ return Select)  >>=  comp
-- @
vote
      :: ( Serialize b
         , Serialize [b]
         , Typeable b
         , HasFork io
         , CMC.MonadCatchIO io)
      => Integer
      -> [a -> Workflow io  b]
      -> ([b] -> Workflow io c)
      -> a
      -> Workflow io c
vote timeout actions comp x=
  split actions x >>= select timeout (const $ return Select)  >>=  comp


-- | sum the outputs of a list of workflows  according with its monoid definition
--
-- @ sumUp timeout actions = vote timeout actions (return . mconcat) @
sumUp
  :: ( Serialize b
     , Serialize [b]
     , Typeable b
     , Monoid b
     , HasFork io
     , CMC.MonadCatchIO io)
     => Integer
     -> [a -> Workflow io b]
     -> a
     -> Workflow io b
sumUp timeout actions = vote timeout actions (return . mconcat)





