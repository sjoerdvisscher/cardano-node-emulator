{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}

module Cardano.Node.Socket.Emulator.Query (handleQuery) where

import Cardano.Api qualified as C
import Cardano.Api.Shelley qualified as C
import Cardano.Slotting.Slot (WithOrigin (..))
import Control.Concurrent (MVar, readMVar)
import Control.Lens (alaf)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Monoid (Ap (Ap))
import Data.SOP (K (K))
import Data.SOP.Strict (NS (S, Z))
import Data.Set qualified as Set
import Ledger.Tx.CardanoAPI (fromPlutusIndex)
import Ouroboros.Consensus.Cardano.Block (BlockQuery (..), CardanoBlock)
import Ouroboros.Consensus.HardFork.Combinator (QueryHardFork (..))
import Ouroboros.Consensus.HardFork.Combinator qualified as Consensus
import Ouroboros.Consensus.Ledger.Query (Query (..))
import Ouroboros.Consensus.Protocol.Praos (Praos)
import Ouroboros.Consensus.Shelley.Eras (BabbageEra, StandardCrypto)
import Ouroboros.Consensus.Shelley.Ledger qualified as Shelley
import Ouroboros.Consensus.Shelley.Ledger.Query (BlockQuery (..))
import Ouroboros.Network.Block qualified as O

import Cardano.Node.Emulator.API qualified as E
import Cardano.Node.Emulator.Internal.Node.Params (
  Params (..),
  emulatorEraHistory,
  genesisDefaultsFromParams,
 )
import Cardano.Node.Emulator.Internal.Node.TimeSlot (posixTimeToUTCTime, scSlotZeroTime)
import Cardano.Node.Socket.Emulator.Types (
  AppState (..),
  getTip,
  runChainEffects,
 )

handleQuery
  :: (block ~ CardanoBlock StandardCrypto)
  => MVar AppState
  -> Query block result
  -> IO result
handleQuery state = \case
  BlockQuery (QueryIfCurrentBabbage q) -> do
    (_logs, res) <- runChainEffects state $ queryIfCurrentBabbage q
    either (printError . show) (pure . Right) res
  BlockQuery (QueryHardFork GetInterpreter) -> do
    AppState _ _ params <- readMVar state
    let C.EraHistory interpreter = emulatorEraHistory params
    pure interpreter
  BlockQuery (QueryHardFork GetCurrentEra) -> do
    pure $ Consensus.EraIndex (S (S (S (S (S (Z (K ()))))))) -- BabbageEra
  BlockQuery q -> printError $ "Unimplemented BlockQuery received: " ++ show q
  GetSystemStart -> do
    AppState _ _ Params{pSlotConfig} <- readMVar state
    pure $ C.SystemStart $ posixTimeToUTCTime $ scSlotZeroTime pSlotConfig
  GetChainBlockNo -> do
    tip <- getTip state
    case tip of
      O.TipGenesis -> pure Origin
      (O.Tip _ _ curBlockNo) -> pure $ At curBlockNo
  GetChainPoint -> printError "Unimplemented: GetChainPoint"

queryIfCurrentBabbage
  :: (block ~ Shelley.ShelleyBlock (Praos StandardCrypto) (BabbageEra StandardCrypto))
  => BlockQuery block result
  -> E.EmulatorT IO result
queryIfCurrentBabbage = \case
  GetGenesisConfig -> Shelley.compactGenesis . genesisDefaultsFromParams <$> E.getParams
  GetCurrentPParams -> emulatorPParams <$> E.getParams
  GetStakePools -> pure mempty
  GetUTxOByAddress addrs ->
    fromPlutusIndex <$> alaf Ap foldMap (E.utxosAt . C.fromShelleyAddrIsSbe C.shelleyBasedEra) addrs
  GetUTxOByTxIn txIns -> fromPlutusIndex <$> E.utxosAtTxIns (Set.map C.fromShelleyTxIn txIns)
  q -> printError $ "Unimplemented BlockQuery(QueryIfCurrentBabbage) received: " ++ show q

printError :: (MonadIO m) => String -> m a
printError s = liftIO (print s) >> error s