-- | Block processing related workers.

module Pos.Worker.Block
       ( blkOnNewSlot
       , blkWorkers
       ) where

import           Control.Lens              (ix, (^.), (^?))
import           Control.TimeWarp.Logging  (logDebug, logInfo, logWarning)
import           Control.TimeWarp.Timed    (Microsecond, for, repeatForever, wait)
import           Formatting                (build, sformat, (%))
import           Serokell.Util.Exceptions  ()
import           Serokell.Util.Text        (listJson)
import           Universum

import           Pos.Communication.Methods (announceBlock)
import           Pos.Constants             (networkDiameter, slotDuration)
import           Pos.Slotting              (MonadSlots (getCurrentTime), getSlotStart)
import           Pos.State                 (createNewBlock, getHeadBlock, getLeaders)
import           Pos.Types                 (SlotId (..), Timestamp (Timestamp), gbHeader,
                                            gbHeader, slotIdF)
import           Pos.WorkMode              (WorkMode, getNodeContext, ncPublicKey,
                                            ncSecretKey)

-- | Action which should be done when new slot starts.
blkOnNewSlot :: WorkMode m => SlotId -> m ()
blkOnNewSlot slotId@SlotId {..} = do
    leadersMaybe <- getLeaders siEpoch
    case leadersMaybe of
        Nothing -> logWarning "Leaders are not known for new slot"
        Just leaders -> do
            let logLeadersF = if siSlot == 0 then logInfo else logDebug
            logLeadersF (sformat ("Slot leaders: " %listJson) leaders)
            ourPk <- ncPublicKey <$> getNodeContext
            let leader = leaders ^? ix (fromIntegral siSlot)
            when (leader == Just ourPk) $ onNewSlotWhenLeader slotId

onNewSlotWhenLeader :: WorkMode m => SlotId -> m ()
onNewSlotWhenLeader slotId = do
    logInfo $
        sformat
            ("I am leader of " %slotIdF % ", I will create block soon")
            slotId
    nextSlotStart <- getSlotStart (succ slotId)
    currentTime <- getCurrentTime
    let timeToCreate =
            max currentTime (nextSlotStart - Timestamp networkDiameter)
        Timestamp timeToWait = timeToCreate - currentTime
    wait (for timeToWait)
    logInfo "It's time to create a block for current slot"
    sk <- ncSecretKey <$> getNodeContext
    let whenCreated createdBlk = do
            logInfo $ sformat ("Created a new block:\n" %build) createdBlk
            announceBlock $ createdBlk ^. gbHeader
    let whenNotCreated = logWarning "I couldn't create a new block"
    maybe whenNotCreated whenCreated =<< createNewBlock sk slotId

-- | All workers specific to block processing.
-- Exceptions:
-- 1. Worker which ticks when new slot starts.
blkWorkers :: WorkMode m => [m ()]
blkWorkers = [blocksTransmitter]

blocksTransmitterInterval :: Microsecond
blocksTransmitterInterval = slotDuration `div` 2

blocksTransmitter :: WorkMode m => m ()
blocksTransmitter =
    repeatForever blocksTransmitterInterval onError $
    do headBlock <- getHeadBlock
       case headBlock of
           Left _          -> logDebug "Head block is genesis block ⇒ no announcement"
           Right mainBlock -> announceBlock (mainBlock ^. gbHeader)
  where
    onError e =
        blocksTransmitterInterval <$
        logWarning (sformat ("Error occured in blocksTransmitter: " %build) e)
