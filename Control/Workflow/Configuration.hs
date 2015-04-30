


{-# OPTIONS
             -XScopedTypeVariables
#-}

{- | Helpers for application initialization -}

module Control.Workflow.Configuration (once, ever, runConfiguration

) where

import Control.Workflow
import Data.Typeable
import Data.RefSerialize
import Control.Monad.Trans
import Control.Exception
import Control.Monad.Catch as CMC

-------------- configuation
-- | to execute a computation every time it is invoked. A synonimous of `unsafeIOtoWF`
ever:: (Typeable a,Serialize a, MonadIO m) => IO a -> Workflow m a
ever=  unsafeIOtoWF

-- | to execute one computation once . It executes at the first run only
once :: (Typeable a,Serialize a, MonadIO m) => m a -> Workflow m a
once= step

-- | executes a computation with `once` and `ever` statements
-- a synonym of `exec1nc`
runConfiguration :: (  Monad m, MonadIO m, CMC.MonadMask m)
                 => String ->  Workflow m a ->   m  a
runConfiguration  = exec1nc

