module Main where

import Control.Workflow
import Control.Concurrent.STM

main= do
   exec1 "pru" $ do
     f <- getTimeoutFlag $ 24*60*60
     step $ atomically $ waitUntilSTM f
   print "fin"
