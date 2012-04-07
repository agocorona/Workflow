-----------------------------------------------------------------------------
--
-- Module      :  Control.Workflow.Configuration
-- Copyright   :
-- License     :  BSD3
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------
{- Helpers for application initialization


-}

{-# OPTIONS
             -XScopedTypeVariables
#-}

module Control.Workflow.Configuration (once, ever, runConfiguration

) where

import Control.Workflow
import Data.Typeable
import Data.RefSerialize
import Control.Monad.Trans
import Control.Exception

-------------- configuation
-- | to execute a computation every time it is invoked. A synonimous of `unsafeIOtoWF`
ever:: (Typeable a,Serialize a, MonadIO m) => IO a -> Workflow m a
ever=  unsafeIOtoWF

-- | to execute one computation once
once :: (Typeable a,Serialize a, MonadIO m) => m a -> Workflow m a
once= step

runConfiguration confname confProc =  handle (\(e :: SomeException) -> return ())
    $ exec1 confname $ do
       confProc
       error ""
       step $ return ()
