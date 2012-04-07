{-# LANGUAGE
              OverlappingInstances
            , UndecidableInstances
            , ExistentialQuantification
            , ScopedTypeVariables
            , MultiParamTypeClasses
            , FlexibleInstances
            , FlexibleContexts
            , TypeSynonymInstances
            , DeriveDataTypeable
            , CPP
          #-}
{-# OPTIONS -IControl/Workflow       #-}

{- |A workflow can be seen as a persistent thread.
The workflow monad writes a log that permit to restore the thread
at the interrupted point. `step` is the (partial) monad transformer for
the Workflow monad. A workflow is defined by its name and, optionally
by the key of the single parameter passed. The primitives for starting workflows
also restart the workflow when it has been in execution previously.

Thiis module uses Data.Binary serialization. Here  the constraint @DynSerializer w r a@ is equivalent to
@Data.Binary a@

If you need to debug the workflow by reading the log or if you use largue structures that are subject of modifications along the workflow, as is the case
typically of multiuser workflows with documents, then use Text seriialization with "Control.Workflow.Text" instead


A small example that print the sequence of integers in te console
if you interrupt the progam, when restarted again, it will
start from the last  printed number

@module Main where
import Control.Workflow.Binary
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)


mcount n= do `step` $  do
                       putStr (show n ++ \" \")
                       hFlush stdout
                       threadDelay 1000000
             mcount (n+1)
             return () -- to disambiguate the return type

main= `exec1`  \"count\"  $ mcount (0 :: Int)@

-}

module Control.Workflow.Binary
 (
  Workflow --    a useful type name
, WorkflowList
, PMonadTrans (..)
, MonadCatchIO (..)

, throw
, Indexable(..)
, MonadIO(..)
-- * Start/restart workflows
, start
, exec
, exec1d
, exec1
, wfExec
, restartWorkflows
, WFErrors(..)
-- * Lifting to the Workflow monad
, step
, stepControl
, unsafeIOtoWF
-- * References to workflow log values
, WFRef
, getWFRef
, newWFRef
, stepWFRef
, readWFRef
, writeWFRef
-- * Workflow inspect
, getAll
, safeFromIDyn
, getWFKeys
, getWFHistory
, waitFor
, waitForSTM
-- * Persistent timeouts
, waitUntilSTM
, getTimeoutFlag
-- * Trace logging
, logWF
-- * Termination of workflows
, killThreadWF
, killWF
, delWF
, killThreadWF1
, killWF1
, delWF1
-- * Log writing policy
, syncWrite
, SyncMode(..)
)
where
import Control.Workflow.Binary.BinDefs

#include "Workflow.inc.hs"
