{-# LANGUAGE

              MultiParamTypeClasses
            , FlexibleInstances
            , ScopedTypeVariables
            , TypeSynonymInstances
          #-}
module Control.Workflow.Binary.BinDefs where
import Data.RefSerialize
import Control.Workflow.IDynamic
import Control.Workflow.Stat
import Data.TCache.DefaultPersistence(Indexable(..))
import Data.Binary
import Data.Binary.Put
import Data.Binary.Get
import System.IO.Unsafe
import Data.IORef
import  Data.ByteString.Lazy.Char8 as B hiding (index)
import Data.Map as M
import Control.Concurrent(ThreadId,forkIO)
import Data.Typeable
import Data.TCache


instance Binary a => Serializer PutM Get a where
  serial     = put
  deserial   = get

instance  RunSerializer PutM Get  where
  runSerial   = runPut
  runDeserial = runGet

instance Binary a => DynSerializer PutM Get a

--instance  TwoSerializer PutM Get PutM Get () ()

instance Binary IDynamic where
   put (IDyn t) =
     case unsafePerformIO $ readIORef t of
      DRight x ->  put . runSerial $ serial x
      DLeft (s, _) ->  put s

   get =  do
     s <- get
     return $ IDyn . unsafePerformIO . newIORef $ DLeft (s, (undefined, pack ""))



instance Binary Stat where
  put (Running map)= do
    put (0 :: Word8)
    put $ Prelude.map (\(k,(w,_))  -> (k,w)) $ M.toList map

  put  (Stat wfName state index recover  versions _) = do
    put (1 :: Word8)
    put wfName
    put state
    put index
    put recover
    put versions

  get = do
   t <- get :: Get Word8
   case t of
    0 -> do list <- get
            return . Running  . M.fromList $ Prelude.map(\(k,w)-> (k,(w,Nothing))) list
    1 -> do
          wfName <- get
          state <- get
          index <- get
          recover <- get
          versions <- get
          return $ Stat wfName  state  index recover  versions   Nothing

instance Binary ThreadId where
  put _= put $ pack "th"
  get = get >>= \(_ :: String) -> return $ unsafePerformIO .  forkIO $ return ()


instance Binary (WFRef a) where
  put (WFRef n ref)= do
     put n
     put $ keyObjDBRef ref

  get= do
     n <- get
     k <- get
     return . WFRef n $ getDBRef k


instance Indexable String where
  key= id

instance Indexable Int where
  key= show

instance Indexable Integer where
  key= show

instance Indexable Stat where
   key  s@Stat{wfName=name}=  "Stat#" ++ name
   key (Running _)= keyRunning
   defPath= const  $ defPath "" ++ "WorkflowState/bin/"

