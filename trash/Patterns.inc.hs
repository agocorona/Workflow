
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



