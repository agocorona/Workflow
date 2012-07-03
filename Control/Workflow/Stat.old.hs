{-# OPTIONS  -XUndecidableInstances
             -XDeriveDataTypeable
             -XTypeSynonymInstances
             -XExistentialQuantification
             -XMultiParamTypeClasses
             -XFlexibleInstances
             -XOverloadedStrings

          #-}
module Control.Workflow.Stat where

import Data.TCache

import Data.ByteString.Lazy.Char8(pack, unpack)
import System.IO.Unsafe
import Data.Typeable
import qualified Data.Map as M
import Control.Concurrent(ThreadId)
import Control.Concurrent.STM(TVar, newTVarIO)
import Data.IORef
import Data.RefSerialize
import Control.Workflow.IDynamic
import Control.Monad(replicateM)
import Data.TCache.DefaultPersistence
import  Data.ByteString.Lazy.Char8 hiding (index)
import Control.Workflow.IDynamic
import Control.Concurrent(forkIO)


data WF  s m l = WF { st :: s -> m (s,l) }


data Stat =  Running (M.Map String (String, (Maybe ThreadId)))
          | Stat{ wfName :: String
                , state:: Int
                , index :: Int
                , recover:: Bool
                , versions :: [IDynamic]
                , lastActive :: Integer
                , timeout :: Maybe Integer
                , self :: DBRef Stat
                }
           deriving (Typeable)

stat0 = Stat{ wfName="",  state=0, index=0, recover=False, versions = []
                   , lastActive=0,   timeout= Nothing, self=getDBRef ""}


statPrefix= "Stat/"
instance Indexable Stat where
   key s@Stat{wfName=name}=  statPrefix ++ name
   key (Running _)= keyRunning
   defPath _=  (defPath (1:: Int)) ++ "Workflow/"


instance  Serialize Stat where
    showp (Running map)= do
          insertString $ pack "Running"
          showp $ Prelude.map (\(k,(w,_))  -> (k,w)) $ M.toList map


    showp  stat@( Stat wfName state index recover  versions act tim _)=do
                     insertString $ pack "Stat"
                     showpText wfName
                     showpText state
                     showpText index
                     showpText recover
                     showp versions
                     showp act
                     insertChar('(')
                     showp tim
                     insertChar(')')


    readp = choice [rStat, rWorkflows] where
        rStat= do
              symbol "Stat"
              wfName     <- stringLiteral
              state      <- integer >>= return . fromIntegral
              index      <- integer >>= return . fromIntegral
              recover    <- bool
              versions   <- readp
              act        <- readp
              tim        <- parens readp
              let self= getDBRef $ key stat0{wfName= wfName}
              return $ Stat wfName  state  index recover  versions act  tim self
              <?> "Stat"

        rWorkflows= do
               symbol "Running"
               list <- readp
               return $ Running $ M.fromList $ Prelude.map(\(k,w)-> (k,(w,Nothing))) list
               <?> "RunningWoorkflows"


-- return the unique name of a workflow with a parameter (executed with exec or start)
keyWF :: Indexable a => String -> a -> String
keyWF wn x= wn ++ "/" ++ key x


data WFRef a= WFRef !Int !(DBRef Stat)  deriving (Typeable, Show)

instance Indexable (WFRef a) where
    key (WFRef n ref)= keyObjDBRef ref++('#':show n)






instance  Serialize a  => Serializable a  where
  serialize = runW . showp
  deserialize = runR readp




keyRunning= "Running"




instance Serialize ThreadId where
  showp th= return () -- insertString . pack $ show th
  readp = {-(readp `asTypeOf` return ByteString) >>-} (return . unsafePerformIO .  forkIO $ return ())



-- | show the state changes along the workflow, that is, all the intermediate results
showHistory :: Stat -> ByteString
showHistory (Stat wfName state index recover  versions  _ _ _)=  runW  sp
    where
    sp  = do
            insertString $ pack "Workflow name= "
            showp wfName
            insertString $ pack "\n"
            showElem  $ Prelude.reverse $ (Prelude.zip ( Prelude.reverse [1..] ) versions )


--    showElem :: [(Int,IDynamic)] -> STW ()
    showElem [] = insertChar '\n'
    showElem ((n , dyn):es) = do
         showp $ pack "Step "
         showp (n :: Int)
         showp $ pack ": "
         showp  dyn
         insertChar '\n'
         showElem es


instance Indexable String where
  key= id

instance Indexable Int where
  key= show

instance Indexable Integer where
  key= show


wFRefStr = "WFRef"

instance  Serialize (WFRef a) where
  showp (WFRef n ref)= do
     insertString $ pack wFRefStr
     showp n
     showp $ keyObjDBRef ref

  readp= do
     symbol wFRefStr
     n <- readp
     k <- readp
     return . WFRef n $ getDBRef k



