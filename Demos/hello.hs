
module Main where
import Control.Workflow
import Data.TCache hiding (syncWrite,SyncManual)


main = do
 syncWrite SyncManual
 getName >>= putStrLn
 getName >>= putStrLn
 syncCache


getName= exec1nc "test" $ do
    name <- step $ do
               putStrLn "your name?"
               getLine
    surname <- step $ do
               putStrLn "your surname?"
               getLine

    return $ "hello " ++ name++ " "++ surname

