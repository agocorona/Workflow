{-# OPTIONS -XDeriveDataTypeable  #-}
-- this program imput numbers and calculate their factorials. The workflow control a record all the inputs and outputs
-- so that when the program restart, all the previous results are shown.
-- if the program abort by a runtime error or a power failure, the program will still work
-- enter 0 for exit and finalize the workflow (all the intermediate data will be erased)
-- enter any alphanumeric character for aborting and then re-start.

module Main where
import Control.Workflow
import Data.Typeable
import Data.Binary
import Data.RefSerialize
import Data.Maybe


fact 0 =1
fact n= n * fact (n-1)


-- now the  workflow versión
data Fact= Fact Integer Integer deriving  (Typeable, Read, Show)



instance Binary Fact where
   put (Fact n v)= put n >> put v
   get=  do
     n <- get
     v <- get
     return $ Fact n v

instance Serialize Fact where
  showp= showpBinary
  readp= readpBinary

factorials = do
  all <- getAll
  let lfacts =  mapMaybe safeFromIDyn all :: [Fact]
  unsafeIOtoWF $ putStrLn "Factorials calculated so far:"
  unsafeIOtoWF $ mapM (\fct -> print fct) lfacts
  factLoop (Fact 0 1)
  where
  factLoop fct=  do
    nf <- plift $ do    -- plift == step
         putStrLn "give me a number if you enter a letter or 0, the program will abort. Then, please restart to see how the program continues"
         str<-  getLine
         let n= read str :: Integer   -- if you enter alphanumeric characters the program will abort. please restart
         let fct=  fact n
         print fct
         return $ Fact n fct

    case nf of
     Fact 0 _ -> do
          unsafeIOtoWF $ print "bye"
          return (Fact 0 0)
     _ -> factLoop nf


main =  exec1  "factorials" factorials
