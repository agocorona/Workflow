{-# LANGUAGE  OverlappingInstances
            , UndecidableInstances
            , ExistentialQuantification
            , ScopedTypeVariables
            , MultiParamTypeClasses
            , FlexibleInstances
            , FlexibleContexts
            , TypeSynonymInstances
            , DeriveDataTypeable

          #-}
{-# OPTIONS -IControl/Workflow       #-}


{- | A workflow can be seen as a persistent thread.
The workflow monad writes a log that permit to restore the thread
at the interrupted point. `step` is the (partial) monad transformer for
the Workflow monad. A workflow is defined by its name and, optionally
by the key of the single parameter passed. The primitives for starting workflows
also restart the workflow when it has been in execution previously.

This is the main module that uses the `RefSerialize` paclkage for serialization. Here  the constraint @DynSerializer w r a@ is equivalent to
@Data.RefSerialize a@

For workflows that uses  big structures, for example, documents
use this module in combination with the RefSerialize package to define  the (de)serialization instances
The log size will be reduced. printWFHistory` method will print the structure changes
in each step.

If instead of RefSerialize, you define read and show instances, there will
 be no reduction. but still the log will be readable for debugging purposes.

Data.Binary instances are also fine for serialization. To use Binary, just define a binary instance
of your data and Include this:

@instance  Serialize <YourData> where
  showp= showpBinary
  readp= readpBibary
@

A small example that print the sequence of integers in te console
if you interrupt the progam, when restarted again, it will
start from the last  printed number

@module Main where
import Control.Workflow.Text
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)


mcount n= do `step` $  do
                       putStr (show n ++ \" \")
                       hFlush stdout
                       threadDelay 1000000
             mcount (n+1)
             return () -- to disambiguate the return type

main= `exec1`  \"count\"  $ mcount (0 :: Int)@

-}

module Control.Workflow

(
  Workflow --    a useful type name
, WorkflowList
, PMonadTrans (..)
, MonadCatchIO (..)
, throw
, Indexable(..)
-- * Start/restart workflows
, start
, exec
, exec1d
, exec1
, wfExec
, startWF
, restartWorkflows
, WFErrors(..)
-- * Lifting to the Workflow monad
, step
, stepControl
, unsafeIOtoWF
-- * References to intermediate values in the workflow log
, WFRef
, getWFRef
, newWFRef
, stepWFRef
, readWFRef
-- * state manipulation
, writeWFRef
, moveState
-- * Workflow inspect
, waitWFActive
, getAll
, safeFromIDyn
, getWFKeys
, getWFHistory
, waitFor
, waitForSTM
-- * Persistent timeouts
, waitUntilSTM
, getTimeoutFlag
, withTimeout
, withKillTimeout
-- * Trace logging
, logWF
-- * Termination of workflows
, clearRunningFlag
, killThreadWF
, killWF
, delWF
, killThreadWF1
, killWF1
, delWF1
, delWFHistory
, delWFHistory1
-- * Log writing policy
, syncWrite
, SyncMode(..)
-- * Print log history
, printHistory
)

where

import Prelude hiding (catch)
import System.IO.Unsafe
import Control.Monad(when,liftM)
import qualified Control.Exception as CE (Exception,AsyncException(ThreadKilled), SomeException, ErrorCall, throwIO, handle,finally,catch,block,unblock)
import Control.Concurrent (forkIO,threadDelay, ThreadId, myThreadId, killThread)
import Control.Concurrent.STM
import GHC.Conc(unsafeIOToSTM)
import GHC.Base (maxInt)


import  Data.ByteString.Lazy.Char8 as B hiding (index)
import Data.ByteString.Lazy  as BL(putStrLn)
import Data.List as L
import Data.Typeable
import System.Time
import Control.Monad.Trans
import Control.Concurrent.MonadIO(HasFork(..),MVar,newMVar,takeMVar,putMVar)


import System.IO(hPutStrLn, stderr)
import Data.List(elemIndex)
import Data.Maybe
import Data.IORef
import System.IO.Unsafe(unsafePerformIO)
import  Data.Map as M(Map,fromList,elems, insert, delete, lookup,toList, fromList,keys)
import qualified Control.Monad.CatchIO as CMC
import qualified Control.Exception.Extensible as E

import Data.TCache
import Data.TCache.DefaultPersistence
import Data.RefSerialize
import Control.Workflow.IDynamic
import Unsafe.Coerce
import Control.Workflow.Stat

--import Debug.Trace
--a !> b= trace b a


type Workflow m = WF  Stat  m   -- not so scary

type WorkflowList m a b= [(String,  a -> Workflow m  b) ]


instance Monad m =>  Monad (WF  s m) where
    return  x = WF (\s ->  return  (s, x))
    WF g >>= f = WF (\s -> do
                (s1, x) <- g s
                let WF fun=  f x
                (s3, x') <- fun s1
                return (s3, x'))



instance (Monad m,Functor m)  => Functor (Workflow m ) where
  fmap f (WF g)= WF (\s -> do
                (s1, x) <- g s
                return (s1, f x))

tvRunningWfs =  getDBRef $ keyRunning :: DBRef Stat



-- | executes a  computation inside of the workflow monad whatever the monad encapsulated in the workflow.
-- Warning: this computation is executed whenever
-- the workflow restarts, no matter if it has been already executed previously. This is useful for intializations or debugging.
-- To avoid re-execution when restarting  use:   @'step' $  unsafeIOtoWF...@
--
-- To perform IO actions in a workflow that encapsulates an IO monad, use step over the IO action directly:
--
--        @ 'step' $ action @
--
-- instead   of
--
--      @  'step' $ unsafeIOtoWF $ action @
unsafeIOtoWF ::   (Monad m) => IO a -> Workflow m a
unsafeIOtoWF x= let y= unsafePerformIO ( x >>= return)  in y `seq` return y


{- |  PMonadTrans permits |to define a partial monad transformer. They are not defined for all kinds of data
but the ones that have instances of certain classes.That is because in the lift instance code there are some
hidden use of these classes.  This also may permit an accurate control of effects.
An instance of MonadTrans is an instance of PMonadTrans
-}
class PMonadTrans  t m a  where
      plift :: Monad m => m a -> t m a



-- | plift= step
instance  (Monad m
          , MonadIO m
          , Serialize a
          , Typeable a)
          => PMonadTrans (WF Stat)  m a
          where
     plift = step

-- |  An instance of MonadTrans is an instance of PMonadTrans
instance (MonadTrans t, Monad m) => PMonadTrans t m a where
    plift= Control.Monad.Trans.lift

instance Monad m => MonadIO (WF Stat  m) where
   liftIO=unsafeIOtoWF


{- | adapted from MonadCatchIO-mtl. Workflow need to express serializable constraints about the  returned values,
so the usual class definitions for lifting IO functions are not suitable.
-}

class  MonadCatchIO m a where
    -- | Generalized version of 'E.catch'
    catch   :: E.Exception e => m a -> (e -> m a) -> m a

    -- | Generalized version of 'E.block'
    block   :: m a -> m a

    -- | Generalized version of 'E.unblock'
    unblock :: m a -> m a



-- | Generalized version of 'E.throwIO'
throw :: (MonadIO m, E.Exception e) => e -> m a
throw = liftIO . E.throwIO





instance (Serialize a
         , Typeable a,MonadIO m, CMC.MonadCatchIO m)
         => MonadCatchIO (WF Stat m) a where
   catch exp exc = do
     expwf <- step $ getTempName
     excwf <- step $ getTempName
     step $ do
        ex <- CMC.catch (exec1d expwf exp >>= return . Right
                                           ) $ \e-> return $ Left e

        case ex of
           Right r -> return r                -- All right
           Left  e ->exec1d excwf (exc e)
                         -- An exception occured in the main workflow
                         -- the exception workflow is executed




   block   exp=WF $ \s -> CMC.block (st exp $ s)

   unblock exp=  WF $ \s -> CMC.unblock (st exp $ s)



instance  (HasFork io
          , CMC.MonadCatchIO io)
          => HasFork (WF Stat  io) where
   fork f = do
    (str, finished) <- step $ getTempName >>= \n -> return(n, False)
    r <- getWFRef
    WF (\s ->
       do th <- if finished
                   then  fork $ return ()
                   else fork $ do
                               exec1 str f
                               liftIO $ do atomically $ writeWFRef r (str, True)
                                           syncIt
          return(s,th))




-- | start or restart an anonymous workflow inside another workflow
--  its state is deleted when finished and the result is stored in
--  the parent's WF state.
wfExec
  :: (Indexable a, Serialize a, Typeable a
  ,  CMC.MonadCatchIO m, MonadIO m)
  => Workflow m a -> Workflow m  a
wfExec f= do
      str <- step $ getTempName
      step $ exec1 str f

-- | a version of exec1 that deletes its state after complete execution or thread killed
exec1d :: (Serialize b, Typeable b
          ,CMC.MonadCatchIO m)
          => String ->  (Workflow m b) ->  m  b
exec1d str f= do
   r <- exec1 str  f
   delit
   return r
  `CMC.catch` (\e@CE.ThreadKilled ->  delit >> throw e)

   where
   delit=  do
     delWF str ()
     liftIO  syncIt  -- !> str



-- | a version of exec with no seed parameter.
exec1 ::  ( Serialize a, Typeable a
          , Monad m, MonadIO m, CMC.MonadCatchIO m)
          => String ->  Workflow m a ->   m  a

exec1 str f=  exec str (const f) ()




-- | start or continue a workflow with exception handling
-- | the workflow flags are updated even in case of exception
-- | `WFerrors` are raised as exceptions
exec :: ( Indexable a, Serialize a, Serialize b, Typeable a
        , Typeable b
        , Monad m, MonadIO m, CMC.MonadCatchIO m)
          => String ->  (a -> Workflow m b) -> a ->  m  b
exec str f x =
       (do
            v <- getState str f x
            case v of
              Right (name, f, stat) -> do
                 r <- runWF name (f x) stat
                 return  r
              Left err -> CMC.throw err)
     `CMC.catch`
       (\(e :: CE.SomeException) -> liftIO $ do
             let name=  keyWF str x
             clearRunningFlag name  --`debug` ("exception"++ show e)
             syncIt
             CMC.throw e )




mv :: MVar Int
mv= unsafePerformIO $ newMVar 0

getTempName :: MonadIO m => m String
getTempName= liftIO $ do
     seq <- takeMVar mv
     putMVar mv (seq + 1)
     TOD t _ <- getClockTime
     return $ "anon"++ show t ++ show seq






instance Indexable () where
  key= show

-- | lifts a monadic computation  to the WF monad, and provides  transparent state loging and  resuming of computation
step :: ( Monad m
        , MonadIO m
        , Serialize a
        , Typeable a)
        =>   m a
        ->  Workflow m a
step= stepControl1 False

-- | permits modification of the workflow state by the procedure being lifted
-- if the boolean value is True. This is used internally for control purposes
stepControl :: ( Monad m
        , MonadIO m
        , Serialize a
        , Typeable a)
        =>   m a
        ->  Workflow m a
stepControl= stepControl1 True

stepControl1 :: ( Monad m
        , MonadIO m
        , Serialize a
        , Typeable a)
        => Bool ->  m a
        ->  Workflow m a
stepControl1 isControl mx= WF(\s'' -> do
        let stat= state s''
        let ind= index s''
        if recover s'' && ind < stat
          then  return (s''{index=ind +1 },   fromIDyn $ versions s'' !! (stat - ind-1) )
          else do
            x' <- mx
            let sref = self s''
            s'<- liftIO . atomically $ do
              s <- if isControl
                     then readDBRef  sref  >>= return . fromMaybe (error $ "step: readDBRef: not found:" ++ keyObjDBRef sref)
                     else return s''
              let versionss= versions s
              let dynx=  toIDyn x'
              let ver= dynx: versionss
              let s'= s{ recover= False, versions =  ver, state= state s+1}

              writeDBRef sref s'
              return s'
            liftIO syncIt
            return (s', x') )

--unjustify str Nothing = error str
--unjustify _ (Just x) = return x




-- | start or continue a workflow with no exception handling.
-- | the programmer has to handle inconsistencies in the workflow state
-- | using `killWF` or `delWF` in case of exception.
start
    :: ( CMC.MonadCatchIO m
       , Indexable a
       , Serialize a, Serialize b
       , Typeable a
       , Typeable b)
    => String                        -- ^ name thar identifies the workflow.
    -> (a -> Workflow m b)           -- ^ workflow to execute
    -> a                             -- ^ initial value (ever use the initial value for restarting the workflow)
    -> m  (Either WFErrors b)        -- ^ result of the computation
start namewf f1 v =  do
  ei <- getState  namewf f1 v
  case ei of
      Left error -> return $  Left  error
      Right (name, f, stat) ->
        runWF name (f  v) stat  >>= return  .  Right
    `CMC.catch`
           (\(e :: WFErrors) -> do
                 let name=  keyWF namewf v
                 clearRunningFlag name
                 return $ Left e)
    `CMC.catch`
           (\(e :: CE.SomeException) -> liftIO $ do
                 let name=  keyWF namewf v
                 clearRunningFlag name
    --             syncIt
                 return . Left $ Exception e )


-- | return conditions from the invocation of start/restart primitives
data WFErrors = NotFound  | AlreadyRunning | Timeout | forall e.CE.Exception e => Exception e deriving Typeable

instance Show WFErrors where
  show NotFound= "Not Found"
  show AlreadyRunning= "Already Running"
  show Timeout= "Timeout"
  show (Exception e)= "Exception: "++ show e

instance CE.Exception WFErrors

--tvRunningWfs = unsafePerformIO  .    refDBRefIO $  Running (M.fromList [] :: Map String (String, (Maybe ThreadId)))

{-
lookup for any workflow for the entry value v
if namewf is found and is running, return arlready running
    if is not runing, restart it
else  start  anew.
-}


getState  :: (Monad m, MonadIO m, Indexable a, Serialize a, Typeable a)
          => String -> x -> a
          -> m (Either WFErrors (String, x, Stat))
getState  namewf f v= liftIO . atomically $ getStateSTM
 where
 getStateSTM = do
      mrunning <- readDBRef tvRunningWfs
      case mrunning of
       Nothing -> do
               writeDBRef tvRunningWfs  (Running $ fromList [])
               getStateSTM
       Just(Running map) ->  do
         let key= keyWF namewf  v
             stat1= stat0{wfName= key,versions=[toIDyn v],self= sref}
             sref= getDBRef $ keyResource stat1
         case M.lookup key map of
           Nothing -> do                        -- no workflow started for this object
             mythread <- unsafeIOToSTM $ myThreadId
             writeDBRef tvRunningWfs . Running $ M.insert key (namewf,Just mythread) map
             writeDBRef sref stat1
             return $ Right (key, f, stat1)

           Just (wf, started) ->               -- a workflow has been initiated for this object
             if isJust started
                then return $ Left AlreadyRunning                       -- `debug` "already running"
                else  do            -- has been running but not running now
                   mst <- readDBRef sref
                   stat' <- case mst of
                          Nothing -> error $ "getState: Workflow not found: "++ key
                          Just s -> do
                             tnow <- unsafeIOToSTM getTimeSeconds
                             if isJust (timeout s)
                              then if lastActive s+ fromJust(timeout s) > tnow  -- !>("lastActive="++show (lastActive s) ++ "tnow="++show tnow)
                                       then
                                         return s{index=0,recover= True,timeout=Nothing}
                                       else
                                         -- has been inactive for too much time, clean it
                                         return stat1
                              else     return s{index=0,recover= True}


                   writeDBRef sref stat'
                   mythread <- unsafeIOToSTM $ myThreadId
                   writeDBRef tvRunningWfs . Running $ M.insert key (namewf,Just mythread) map

                   return $ Right (key, f, stat')

syncIt= do
   (sync,_) <-  atomically $ readTVar  tvSyncWrite
   when (sync ==Synchronous)  syncCache

runWF :: (Monad m,MonadIO m
         , Serialize b, Typeable b)
         =>  String ->  Workflow m b -> Stat  -> m  b
runWF n f s= do
   (sync,_) <-  liftIO $ atomically $ readTVar  tvSyncWrite
--   sync <- liftIO $!  do
--          (sync,_) <-  atomically $ readTVar  tvSyncWrite
--          when (sync ==Synchronous)  syncCache
--          return sync
   (s', v')  <-  st f $ s -- !> (show $ versions s)
   liftIO $! do
          clearFromRunningList n
          when (sync ==Synchronous)   syncCache
   return  v'
   where

   -- eliminate the thread from the list of running workflows but leave the state
   clearFromRunningList n = atomically $ do
      Just(Running map) <-  readDBRef tvRunningWfs
      writeDBRef tvRunningWfs . Running $ M.delete   n   map -- `debug` "clearFromRunningList"

-- | start or continue a workflow  from a list of workflows in the IO monad with exception handling. The excepton is returned as a Left value
startWF
    ::  ( CMC.MonadCatchIO m
        , Serialize a, Serialize b
        , Typeable a
        , Indexable a
        , Typeable b)
    =>  String                        -- ^ name of workflow in the workflow list
    -> a                             -- ^ initial value (ever use the initial value even to restart the workflow)
    -> WorkflowList m  a b              -- ^ function to execute
    -> m (Either WFErrors b)        -- ^  result of the computation
startWF namewf v wfs=
   case Prelude.lookup namewf wfs of
     Nothing -> return $ Left NotFound
     Just f -> start namewf f v



-- | re-start the non finished workflows in the list, for all the initial values that they may have been called
restartWorkflows
   :: (Serialize a, Serialize b, Typeable a
   , Indexable b,   Typeable b)
   =>  WorkflowList IO a b      -- the list of workflows that implement the module
   -> IO ()                    -- Only workflows in the IO monad can be restarted with restartWorkflows
restartWorkflows map = do
  mw <- liftIO $ getResource ((Running undefined ) )  -- :: IO (Maybe(Stat a))
  case mw of
    Nothing -> return ()
    Just (Running all) ->  mapM_ start . mapMaybe  filter  . toList  $ all
  where
  filter (a, (b,Nothing)) =  Just  (b, a)
  filter _  =  Nothing

  start (key, kv)= do


      let mf= Prelude.lookup key map
      case mf of
        Nothing -> return ()
        Just  f -> do
          let st0= stat0{wfName = kv}
          mst <- liftIO $ getResource st0
          case mst of
                   Nothing -> error $ "restartWorkflows: workflow not found "++ keyResource st0
                   Just st-> do
                     liftIO  .  forkIO $ runWF key (f (fromIDyn . Prelude.last $ versions st )) st{index=0,recover=True} >> return ()
                     return ()

-- | executes a computation in a loop until a condition is met
-- the intermediate loop results are not stored, but at recovery
-- , the loop restart at the last state that it was before shutdown.
loop
  :: (Monad m,MonadIO m, Typeable b, Serialize b) =>
     (b -> m b) -> b -> (b -> Bool) -> WF Stat m b
loop f x  cond = override f x>>= \x -> if cond x then return x else loop f x cond
  where
  override f x= do
    r <- step $ f x

    WF $ \s ->
      if recover s && index s < state s
          then    return (s{index= index s -1},r)
          else    return (s{state= state s -1},r)




-- |
-- The execution log is cached in memory using the package `TCache`. This procedure defines the polcy for writing the cache into permanent storage.
--
-- For fast workflows, or when TCache` is used also for other purposes ,  `Asynchronous` is the best option
--
-- `Asynchronous` mode  invokes `clearSyncCache`. For more complex use of the syncronization
-- please use this `clearSyncCache`.
--
-- When interruptions are  controlled, use `SyncManual` mode and include a call to `syncCache` in the finalizaton code

syncWrite::  (Monad m, MonadIO m) => SyncMode -> m ()
syncWrite mode= do
 (_,thread) <- liftIO . atomically $ readTVar tvSyncWrite
 when (isJust thread ) $ liftIO . killThread . fromJust $ thread
 case mode of
    Synchronous -> modeWrite
    SyncManual  -> modeWrite
    Asyncronous time maxsize -> do
       th <- liftIO  $ clearSyncCacheProc  time defaultCheck maxsize >> return()
       liftIO . atomically $ writeTVar tvSyncWrite (mode,Just th)
 where
 modeWrite=
   liftIO . atomically $ writeTVar tvSyncWrite (mode, Nothing)


-- | return all the steps of the workflow log. The values are dynamic
--
-- to get all the steps  with result of type Int:
--  @all <- `getAll`
--  let lfacts =  mapMaybe `safeFromIDyn` all :: [Int]@
getAll :: Monad m => Workflow m [IDynamic]
getAll=  WF(\s -> return (s, versions s))


-- | return the list of object keys that are running for a workflow
getWFKeys :: String -> IO [String]
getWFKeys wfname= do
      mwfs <- atomically $ readDBRef tvRunningWfs
      case mwfs of
       Nothing   -> return  []
       Just (Running wfs)   -> return $ Prelude.filter (L.isPrefixOf wfname) $ M.keys wfs

-- | return the current state of the computation, in the IO monad
getWFHistory :: (Indexable a, Serialize a) => String -> a -> IO (Maybe Stat)
getWFHistory wfname x=  getResource stat0{wfName=  keyWF wfname  x}

-- | delete the history of a workflow.
-- Be sure that this WF has finished.
{-# DEPRECATED delWFHistory, delWFHistory1 "use delWF and delWF1 instead" #-}

delWFHistory name1 x = do
      let name= keyWF name1 x
      delWFHistory1 name

delWFHistory1 name  = do
      let proto= stat0{wfName= name}
--      when (isJust mdir) $
--           moveFile (defPath proto ++ key proto)  (defPath proto ++ fromJust mdir)
      atomically . withSTMResources [] $ const resources{  toDelete= [proto] }


waitWFActive wf= do
      r <- threadWF wf
      case r of        -- wait for change in the wofkflow state
            Just (_, Nothing) -> retry
            _ -> return ()
      where
      threadWF wf= do
               Just(Running map) <-  readDBRef tvRunningWfs
               return $ M.lookup wf map


-- | kill the executing thread if not killed, but not its state.
-- `exec` `start` or `restartWorkflows` will continue the workflow
killThreadWF :: ( Indexable a
                , Serialize a

                , Typeable a
                , MonadIO m)
       => String -> a -> m()
killThreadWF wfname x= do
  let name= keyWF wfname x
  killThreadWF1 name

-- | a version of `KillThreadWF` for workflows started wit no parameter by `exec1`
killThreadWF1 ::  MonadIO m => String -> m()
killThreadWF1 name= killThreadWFm name  >> return ()

killThreadWFm name= do
   (map,f) <- clearRunningFlag name
   case f of
    Just th -> liftIO $ killThread th
    Nothing -> return()
   return map



-- | kill the process (if running) and drop it from the list of
--  restart-able workflows. Its state history remains , so it can be inspected with
--  `getWfHistory` `printWFHistory` and so on
killWF :: (Indexable a,MonadIO m) => String -> a -> m ()
killWF name1 x= do
       let name= keyWF name1 x
       killWF1 name

-- | a version of `KillWF` for workflows started wit no parameter by `exec1`
killWF1 :: MonadIO m => String  -> m ()
killWF1 name = do
       map <- killThreadWFm name
       liftIO . atomically . writeDBRef tvRunningWfs . Running $ M.delete   name   map
       return ()

-- | delete the WF from the running list and delete the workflow state from persistent storage.
--  Use it to perform cleanup if the process has been killed.
delWF :: ( Indexable a
         , MonadIO m
         , Typeable a)
        => String -> a -> m()
delWF name1 x=   do
  let name= keyWF name1 x
  delWF1 name


-- | a version of `delWF` for workflows started wit no parameter by `exec1`
delWF1 :: MonadIO m=> String  -> m()
delWF1 name= liftIO $ do
  mrun <- atomically $ readDBRef tvRunningWfs
  case mrun of
    Nothing -> return()
    Just (Running map) -> do
      atomically . writeDBRef tvRunningWfs . Running $! M.delete   name   map
      delWFHistory1 name
      syncIt



clearRunningFlag name= liftIO $ atomically $ do
  mrun <-  readDBRef tvRunningWfs
  case mrun of
   Nothing -> error $ "clearRunningFLag: non existing workflows" ++ name
   Just(Running map) -> do
   case M.lookup  name map of
    Just(_, Nothing) -> return (map,Nothing)
    Just(v, Just th) -> do
      writeDBRef tvRunningWfs . Running $ M.insert name (v, Nothing) map
      return (map,Just th)
    Nothing  ->
      return (map, Nothing)

-- | Return the reference to the last logged result , usually, the last result stored by `step`.
-- wiorkflow references can be accessed outside of the workflow
-- . They also can be (de)serialized.
--
-- WARNING getWFRef can produce  casting errors  when the type demanded
-- do not match the serialized data. Instead,  `newDBRef` and `stepWFRef` are type safe at runtuime.
getWFRef ::  ( Monad m,
               MonadIO m,
               Serialize a
             , Typeable a)
             => Workflow m  (WFRef a)
getWFRef =ret
   where
   ret=   WF (\s -> do
       let     n= if recover s then index s else state s
       let  ref = WFRef n (self s)
       -- to reify the object being accessed
       -- if not reified, the serializer will write a null object
       let r= fromIDyn (versions s !!  (state s - n)) `asTypeOf` typeofRef ret
       r `seq` return  (s,ref))
       where
       typeofRef :: Workflow m  (WFRef a) -> a
       typeofRef= undefined -- never will be executed
-- | Execute  an step but return a reference to the result instead of the result itself
--
-- @stepWFRef exp= `step` exp >>= `getWFRef`@
stepWFRef :: ( Serialize a
           , Typeable a
           , MonadIO m)
            => m a -> Workflow m  (WFRef a)
stepWFRef exp= step exp >> getWFRef

-- | Log a value and return a reference to it.
--
-- @newWFRef x= `step` $ return x >>= `getWFRef`@
newWFRef :: ( Serialize a
           , Typeable a
           , MonadIO m)
           => a -> Workflow m  (WFRef a)
newWFRef x= step (return x) >> getWFRef

-- | Read the content of a Workflow reference. Note that its result is not in the Workflow monad
readWFRef :: ( Serialize a
             , Typeable a)
             => WFRef a
             -> STM (Maybe a)
readWFRef (WFRef n ref)= do
  mr <- readDBRef ref
  case mr of
    Nothing -> return Nothing
    Just s  -> do
      let elems= versions s
          l    =  state s -- L.length elems
          x    = elems !! (l - n)
      return . Just $! fromIDyn x


-- | Writes a new value en in the workflow reference, that is, in the workflow log.
-- Why would you use this?.  Don do that!. modifiying the content of the workflow log would
-- change the excution flow  when the workflow restarts. This metod is used internally in the package
-- the best way to communicate with a workflow is trough a persistent queue:
--
--  @worflow= exec1 "wf" do
--         r <- `stepWFRef`  expr
--         `push` \"queue\" r
--         back <- `pop` \"queueback\"
--         ...
-- @

writeWFRef :: ( Serialize a
                 , Typeable a)
                 => WFRef a
                 -> a
                 -> STM ()
writeWFRef  r@(WFRef n ref) x= do
  mr <- readDBRef ref
  case mr of
    Nothing -> error $ "writeWFRef: workflow does not exist: " ++ keyObjDBRef ref
    Just s  -> do
      let elems= versions s
          l    = state s -- L.length elems
          p    = l - n
          (h,t)= L.splitAt p elems
          elems'= h ++ (toIDyn x:tail' t)
          tail' []= []
          tail' t= L.tail t

      writeDBRef  ref s{ versions= elems'}

-- | moves the state from a seed value to other.
-- This may be of interest when the  entry value
-- changes its key value but  should not initiate a new workflow
-- but continues with the current one

moveState   :: (MonadIO m
             , Indexable a
             , Serialize a
             , Typeable a)
             =>String -> a -> a -> m ()
moveState wf t t'=  liftIO $ do
     atomically $ do
           withSTMResources[stat0{wfName= n}] $ doit n
           mrun <-  readDBRef tvRunningWfs
           case mrun of
                Nothing -> return()
                Just (Running map) -> do
                  let mr= M.lookup n map
                  let th= case mr of Nothing -> Nothing; Just(_,mt)-> mt
                  let map'= M.insert n' (wf,th) $ M.delete n map
                  writeDBRef tvRunningWfs $ Running  map'
     syncIt
     where
     n = keyWF wf t
     n'= keyWF wf t'

     doit n [Just s] = resources{toAdd= [ s{wfName=n',versions = toIDyn t': L.tail( versions s) }]
                                ,toDelete=[s]}

     doit n [Nothing]= error $ "moveState: state not found for: " ++ n



-- | Log a message in the workflow history. I can be printed out with 'printWFhistory'
-- The message is printed in the standard output too
logWF :: MonadIO m => String -> Workflow m  ()
logWF str=do
           str <- step . liftIO $ do
            time <-  getClockTime >>=  toCalendarTime >>= return . calendarTimeToString
            Prelude.putStrLn str
            return $ time ++ ": "++ str
           WF $ \s ->  str  `seq` return (s, ())



--------- event handling--------------


-- | Wait until a TCache object (with a certaing key) meet a certain condition (useful to check external actions )
-- NOTE if anoter process delete the object from te cache, then waitForData will no longuer work
-- inside the wokflow, it can be used by lifting it :
--          do
--                x <- step $ ..
--                y <- step $ waitForData ...
--                   ..

waitForData :: (IResource a,  Typeable a)
              => (a -> Bool)                   -- ^ The condition that the retrieved object must meet
            -> a                             -- ^ a partially defined object for which keyResource can be extracted
            -> IO a                          -- ^ return the retrieved object that meet the condition and has the given kwaitForData  filter x=  atomically $ waitForDataSTM  filter x
waitForData f x = atomically $ waitForDataSTM f x

waitForDataSTM ::  (IResource a,  Typeable a)
                  =>  (a -> Bool)               -- ^ The condition that the retrieved object must meet
                -> a                         -- ^ a partially defined object for which keyResource can be extracted
                -> STM a                     -- ^ return the retrieved object that meet the condition and has the given key
waitForDataSTM  filter x=  do
        tv <- newDBRef  x
        do
                mx  <-  readDBRef tv >>= \v -> return $ cast v
                case mx of
                  Nothing -> retry
                  Just x ->
                    case filter x of
                        False -> retry
                        True  -> return x

-- | observe the workflow log untiil a condition is met.
waitFor
      ::   ( Indexable a, Serialize a, Serialize b,  Typeable a
           , Indexable b,  Typeable b)
      =>  (b -> Bool)                    -- ^ The condition that the retrieved object must meet
      -> String                           -- ^ The workflow name
      -> a                                   -- ^  the INITIAL value used in the workflow to start it
      -> IO b                              -- ^  The first event that meet the condition
waitFor  filter wfname x=  atomically $ waitForSTM  filter wfname x

waitForSTM
      ::   ( Indexable a, Serialize a, Serialize b,  Typeable a
           , Indexable b,  Typeable b)
      =>  (b -> Bool)                    -- ^ The condition that the retrieved object must meet
      -> String                          -- ^ The workflow name
      -> a                               -- ^ The INITIAL value used in the workflow to start it
      -> STM b                           -- ^ The first event that meet the condition
waitForSTM  filter wfname x=  do
    let name= keyWF wfname x
    let tv=  getDBRef . key $ stat0{wfName= name}       -- `debug` "**waitFor***"

    mmx  <-  readDBRef tv
    case mmx of
     Nothing -> error ("waitForSTM: Workflow does not exist: "++ name)
     Just mx -> do
        let  Stat{ versions= d:_}=  mx
        case safeFromIDyn d of
          Nothing -> retry                                            -- `debug` "waithFor retry Nothing"
          Just x ->
            case filter x  of
                False -> retry                                          -- `debug` "waitFor false filter retry"
                True  ->  return x      --  `debug` "waitfor return"



{-# DEPRECATED waitUntilSTM, getTimeoutFlag "use withTimeout instead" #-}
-- | Start the timeout and return the flag to be monitored by 'waitUntilSTM'
-- This timeout is persistent. This means that the time start to count from the first call to getTimeoutFlag on
-- no matter if the workflow is restarted. The time that the worlkflow has been stopped count also.
-- the wait time can exceed the time between failures.
-- when timeout is 0 means no timeout.
getTimeoutFlag
        :: MonadIO m
        => Integer                --  ^ wait time in secods. This timing start from the first time that the timeout was started on. Sucessive restarts of the workflow will respect this timing
       ->  Workflow m (TVar Bool) --  ^ the returned flag in the workflow monad
getTimeoutFlag  0 = WF $ \s ->  liftIO $ newTVarIO False >>= \tv -> return (s, tv)
getTimeoutFlag  t = do
     tnow <- step $ liftIO getTimeSeconds
     flag tnow t
     where
     flag tnow delta = WF $ \s -> do
          tv <- liftIO $ newTVarIO False

          liftIO  $ do
             let t  =  tnow +  delta
             atomically $ writeTVar tv False
             forkIO $  do waitUntil t ;  atomically $ writeTVar tv True
          return (s, tv)

getTimeSeconds :: IO Integer
getTimeSeconds=  do
      TOD n _  <-  getClockTime
      return n

{- | Wait until a certain clock time has passed by monitoring its flag,  in the STM monad.
   This permits to compose timeouts with locks waiting for data using `orElse`

   *example: wait for any respoinse from a Queue  if no response is given in 5 minutes, it is returned True.

  @
   flag <- 'getTimeoutFlag' $  5 * 60
   ap <- 'step'  .  atomically $  readSomewhere >>= return . Just  `orElse`  'waitUntilSTM' flag  >> return Nothing
   case ap of
        Nothing -> do 'logWF' "timeout" ...
        Just x -> do 'logWF' $ "received" ++ show x ...
  @
-}
waitUntilSTM ::  TVar Bool  -> STM()
waitUntilSTM tv = do
        b <- readTVar tv
        if b == False then retry else return ()

-- | Wait until a certain clock time has passed by monitoring its flag,  in the IO monad.
-- See `waitUntilSTM`

waitUntil:: Integer -> IO()
waitUntil t= getTimeSeconds >>= \tnow -> wait (t-tnow)


wait :: Integer -> IO()
wait delta=  do
        let delay | delta < 0= 0
                  | delta > (fromIntegral  maxInt) = maxInt
                  | otherwise  = fromIntegral $  delta
        threadDelay $ delay  * 1000000
        if delta <= 0 then   return () else wait $  delta - (fromIntegral delay )

-- | return either the result of the STM conputation or Nothing in case of timeout
-- This timeout is persistent. This means that the time start to count from the first call to getTimeoutFlag on
-- no matter if the workflow is restarted. The time that the worlkflow has been stopped count also.
-- Thus, the wait time can exceed the time between failures.
-- when timeout is 0 means no timeout.
withTimeout :: ( MonadIO m, Typeable a, Serialize a)=> Integer -> STM a -> Workflow m (Maybe a)
withTimeout time  f = do
  flag <- getTimeoutFlag time
  step . liftIO . atomically $ (f >>=  return  .  Just )
                               `orElse`
                               (waitUntilSTM flag  >> return  Nothing)


-- | executes a computation in the STM monad. If it is not finished after time `time
-- it kill the process. If the workflow is restarted after time2, the workflow
-- will restart from the beginning. If not, it will restart at the last checkpoint.
withKillTimeout :: MonadIO m => String -> Int -> Integer -> STM a -> m a
withKillTimeout id time time2 f = liftIO $ do

  flag <- transientTimeout time 
  r    <- atomically $ (f >>=  return  .  Just )
                       `orElse`
                       (waitUntilSTM flag  >> return  Nothing) 
  case r of 
        Just r  -> return   r
        Nothing -> do
          clearRunningFlag id
          if time2 == 0
               then throw Timeout        -- !> "Timeout"
               else do
                  tnow <- getTimeSeconds
                  withResource stat0{wfName=id} $ \ms -> do
                    case ms of
                      Just s -> s{lastActive= tnow,timeout= Just (time2-fromIntegral time)}
                      Nothing -> error $ "withKillTimeout: Workflow not found: "++ id
                  syncIt                -- !>  ("time2=" ++ show time2)
                  throw Timeout         -- !> "Timeout"


transientTimeout 0= atomically $ newTVar False
transientTimeout t= do
    flag <- atomically $ newTVar False
    forkIO $ threadDelay (t * 1000000) >> atomically (writeTVar flag True) 
    return flag
