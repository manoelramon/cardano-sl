{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Internal block logic. Mostly needed for use in 'Pos.Lrc' -- using
-- lrc requires to apply and rollback blocks, but applying many blocks
-- requires triggering lrc recalculations.

module Pos.Block.Logic.Internal
       ( applyBlocksUnsafe
       , rollbackBlocksUnsafe
       , withBlkSemaphore
       , withBlkSemaphore_
       ) where

import           Control.Arrow        ((&&&))
import           Control.Lens         (each, _Wrapped)
import           Control.Monad.Catch  (bracketOnError)
import           System.Wlog          (logError)
import           Universum

import           Pos.Block.Types      (Blund, Undo (undoUS))
import           Pos.Context          (lrcActionOnEpochReason, putBlkSemaphore,
                                       takeBlkSemaphore)
import           Pos.DB               (SomeBatchOp (..))
import qualified Pos.DB               as DB
import qualified Pos.DB.GState        as GS
import qualified Pos.DB.Lrc           as DB
import           Pos.Delegation.Logic (delegationApplyBlocks, delegationRollbackBlocks)
import           Pos.Ssc.Extra        (sscApplyBlocks, sscApplyGlobalState, sscRollback)
import           Pos.Txp.Logic        (normalizeTxpLD, txApplyBlocks, txRollbackBlocks)
import           Pos.Types            (HeaderHash, epochIndexL, headerHashG, prevBlockL)
import           Pos.Update.Logic     (usApplyBlocks, usNormalize, usRollbackBlocks)
import           Pos.Update.Poll      (PollModifier)
import           Pos.Util             (Color (Red), NE, NewestFirst (..),
                                       OldestFirst (..), colorize, inAssertMode, spanSafe,
                                       _neHead, _neLast)
import           Pos.WorkMode         (WorkMode)


-- | Run action acquiring lock on block application. Argument of
-- action is an old tip, result is put as a new tip.
withBlkSemaphore
    :: WorkMode ssc m
    => (HeaderHash -> m (a, HeaderHash)) -> m a
withBlkSemaphore action =
    bracketOnError takeBlkSemaphore putBlkSemaphore doAction
  where
    doAction tip = do
        (res, newTip) <- action tip
        res <$ putBlkSemaphore newTip

-- | Version of withBlkSemaphore which doesn't have any result.
withBlkSemaphore_
    :: WorkMode ssc m
    => (HeaderHash -> m HeaderHash) -> m ()
withBlkSemaphore_ = withBlkSemaphore . (fmap ((), ) .)

-- | Applies a definitely valid prefix of blocks. This function is unsafe,
-- use it only if you understand what you're doing. That means you can break
-- system guarantees.
--
-- Invariant: all blocks have the same epoch.
applyBlocksUnsafe
    :: forall ssc m . WorkMode ssc m
    => OldestFirst NE (Blund ssc) -> PollModifier -> m ()
applyBlocksUnsafe blunds0 pModifier = do
    -- Note: it's important to put blocks first
    mapM_ putToDB blunds
    usBatch <- SomeBatchOp <$> usApplyBlocks blocks pModifier
    delegateBatch <- SomeBatchOp <$> delegationApplyBlocks blocks
    txBatch <- SomeBatchOp . getOldestFirst <$> txApplyBlocks blunds
    sscApplyBlocks blocks
    let epoch = blunds ^. _Wrapped . _neHead . _1 . epochIndexL
    richmen <-
        lrcActionOnEpochReason epoch "couldn't get SSC richmen" DB.getRichmenSsc
    sscApplyGlobalState richmen
    GS.writeBatchGState [delegateBatch, usBatch, txBatch, forwardLinksBatch, inMainBatch]
    normalizeTxpLD
    usNormalize
    DB.sanityCheckDB
  where
    -- hehe it's not unsafe yet TODO
    (OldestFirst -> blunds, _) =
        spanSafe ((==) `on` view (_1 . epochIndexL)) (getOldestFirst blunds0)
    blocks = fmap fst blunds
    forwardLinks = map (view prevBlockL &&& view headerHashG) $ toList blocks
    forwardLinksBatch = SomeBatchOp $ map (uncurry GS.AddForwardLink) forwardLinks
    inMainBatch = SomeBatchOp . getOldestFirst $
        fmap (GS.SetInMainChain True . view headerHashG . fst) blunds
    putToDB (blk, undo) = DB.putBlock undo blk

-- | Rollback sequence of blocks, head-newest order exepected with
-- head being current tip. It's also assumed that lock on block db is
-- taken.  application is taken already.
rollbackBlocksUnsafe
    :: (WorkMode ssc m)
    => NewestFirst NE (Blund ssc) -> m ()
rollbackBlocksUnsafe toRollback = do
    delRoll <- SomeBatchOp <$> delegationRollbackBlocks toRollback
    usRoll <- SomeBatchOp <$> usRollbackBlocks (toRollback & each._2 %~ undoUS)
    txRoll <- SomeBatchOp <$> txRollbackBlocks toRollback
    sscRollback $ fmap fst toRollback
    GS.writeBatchGState [delRoll, usRoll, txRoll, forwardLinksBatch, inMainBatch]
    DB.sanityCheckDB
    inAssertMode $
        when (isGenesis0 (toRollback ^. _Wrapped . _neLast . _1)) $
        logError $
        colorize Red "FATAL: we are TRYING TO ROLLBACK 0-TH GENESIS block"
  where
    inMainBatch =
        SomeBatchOp . getNewestFirst $
        fmap (GS.SetInMainChain False . view headerHashG . fst) toRollback
    forwardLinksBatch =
        SomeBatchOp . getNewestFirst $
        fmap (GS.RemoveForwardLink . view prevBlockL . fst) toRollback
    isGenesis0 (Left genesisBlk) = genesisBlk ^. epochIndexL == 0
    isGenesis0 (Right _)         = False
