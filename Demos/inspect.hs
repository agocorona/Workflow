{-# LANGUAGE ScopedTypeVariables  #-}
-- example of the Workflow package .
-- This demo shows inter-workflow communications.
-- two workflows that interact by inspecting its other's  state. One ask the user for a numbers.
-- When the total number of tries
-- is exhausted, update Data with termination and ends.
---It can end when termination comes from the other workflow. The other wait for "5", print
-- a message , update Data with termination to the other and finish. t
-- you can break the code at any moment. The flow will re-start in the last interrupted point
-- For bugs, questions, whatever, please email me: Alberto Gómez Corona agocorona@gmail.com

module Main where
import Control.Workflow
--import Debug.Trace
--import Data.Typeable
import Control.Concurrent
import Control.Exception
import System.Exit
import Control.Concurrent.STM


--debug a b = trace b a



-- start_ if the WF was in a intermediate state, restart it
-- A workflow state is identified by:
--          the name of the workflow
--          the key of the object whose worflow was called

main= do
   forkIO $ exec1 "wait" wait  >> return ()
   exec1 "hello-ask" hello
   threadDelay 1000000
   delWF1 "wait"
   delWF1 "hello-ask"



-- ask for numbers or "end". Inspect the step values of the other workflow
-- and exit if the value is "good"
hello :: Workflow IO ()
hello = do
      unsafeIOtoWF $ do
        putStrLn ""
        putStrLn "At any step you can break and re-start the program"
        putStrLn "The program will restart at the interrupted step."
        putStrLn ""
      --syncWrite Synchronous -- this is the default
      name <- step $ do
                print "what is your name?"
                getLine
      step $ putStrLn $ "hello Mr "++  name
      loop 0 name
      where
      loop i name=do
          unsafeIOtoWF $ threadDelay 100000
          str <- step $  do
                putStrLn $ "Mr "++name++ " this is your try number "++show (i+1) ++". Guess my number, press \"end\" to finish"
                getLine
          flag <- getTimeoutFlag 1
          -- waith for any character in any step on the "wait" workflow within one second span
          let  anyString :: String -> Bool
               anyString =  const True
          s <- step . atomically $ (waitForSTM anyString "wait" () >>= return . Just)
                                   `orElse`
                                   (waitUntilSTM flag >> return Nothing )
          case s of
            Just "good" -> return ()
            _           -> loop  (i+1) name


-- wait for a "5" or "end" in any step of the "hello" workflow, put an "good" and exit
wait :: Workflow IO ()
wait = do
      let
          filter "5"   = True
          filter "end" = True
          filter _     = False
      step $ do
         r <- waitFor filter "hello-ask"  ()  -- wait the other thread to store an object with the same key than Try 0 ""
                                              -- with the string "5"  or termination
         case r of
            "5"   ->  print "done ! " >> return "good"  -- put exit in the WF state
            "end" ->  print "end received. Bye" >> return "good"  -- put exit in the WF state

      -- wait for the inspection of the other workflow
      unsafeIOtoWF $ threadDelay 500000




