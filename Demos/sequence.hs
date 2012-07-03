
module Main where
import Control.Workflow
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)

printLine x= do
   putStr (show x ++ " ")
   hFlush stdout
   threadDelay 1000000


mcount :: Int -> Workflow IO ()
mcount n= do step $  printLine n
             mcount (n+1)


main=  exec1  "count"  $ mcount 0
