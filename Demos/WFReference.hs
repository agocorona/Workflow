
module Main where
import Control.Workflow
import Data.TCache
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)
import Control.Concurrent
import qualified Data.ByteString.Lazy.Char8 as B



main= do

   refs <- exec1 "WFRef" $ do
             step $ return (1 :: Int)
             ref <- newWFRef  "bye initial valoe"
             step $ return (3 :: Int)
             return ref

   atomically $ writeWFRef refs "hi final value"
   s <- atomically $   readWFRef refs
   print s
   Just stat <- getWFHistory "WFRef" ()
   B.putStrLn $ showHistory stat
   syncCache
   atomically flushAll

   stat<- getWFHistory "WFRef" () `onNothing` error "stat not found"
   B.putStrLn $ showHistory stat
   s <- atomically $   readWFRef refs
   print s



