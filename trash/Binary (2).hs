{-# OPTIONS  -XDeriveDataTypeable
             -XTypeSynonymInstances
             -XMultiParamTypeClasses
             -XExistentialQuantification
             -XOverloadedStrings
             -XFlexibleInstances
             -XUndecidableInstances
             -XFunctionalDependencies
             -XFlexibleContexts
             -XIncoherentInstances
             -IControl/Workflow
             -XCPP #-}
{-# OPTIONS -IData/Persistent/Queue       #-}
{- |
This module implements a persistent, transactional collection with Queue interface as well as indexed access by key
This module uses `Data.Binary` for serialization.

Here @QueueConstraints w r a@ means  @Data.Binary.Binary a@

For optimal (de)serialization if you store in the queue different versions of largue structures , for
example, documents you better use  "Data.RefSerialize"  and "Data.Persistent.Queue.Text" Instead.

-}
module Data.Persistent.Queue.Binary(
RefQueue(..),  getQRef,
pop,popSTM,pick,Data.Persistent.Queue.Binary.flush, flushSTM,
pickAll, pickAllSTM, push,pushSTM,
pickElem, pickElemSTM,  readAll, readAllSTM,
deleteElem, deleteElemSTM,
unreadSTM,Data.Persistent.Queue.Binary.isEmpty,isEmptySTM
) where
import Data.Typeable
import Control.Concurrent.STM(STM,atomically, retry)
import Control.Monad(when)
import Data.TCache.DefaultPersistence

import Data.TCache
import System.IO.Unsafe
import Data.IORef

import Data.ByteString.Lazy.Char8

import Data.RefSerialize

import Data.Binary
import Data.Binary.Put
import Data.Binary.Get




instance Indexable (Queue a) where
  key (Queue k  _ _)= queuePrefix ++ k
  defPath _=  "WorkflowState/Binary/"

#include "Queue.inc.hs"
