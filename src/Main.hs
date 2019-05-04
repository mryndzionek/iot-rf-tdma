{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent            (forkIO, threadDelay)
import           Control.Concurrent.STM        (atomically, orElse)
import           Control.Concurrent.STM.Delay
import           Control.Concurrent.STM.TQueue
import           Control.Monad                 (replicateM, when)
import           Control.Monad.Loops           (iterateM_)
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Data.Maybe                    (fromMaybe)
import           Data.Time.Clock
import           Data.Time.Format
import           Safe
import           System.Environment
import           System.Random

data GWMsg =
  GWMsg
  deriving (Show)

data NodeMsg
  = NodeMsg Int
  | Timeout
  deriving (Show)

newtype GWState = GWState
  { _timer :: Delay
  }

newtype NodeState = NodeState
  { _rng :: StdGen
  }

-- Global read-only state
data SimCfg = SimCfg
  { _numNodes     :: Int
  , _slotLengthMs :: Int
  }

type SlotId = Int
type GWChan = TQueue GWMsg
type NodeChan = TQueue NodeMsg
type App = ReaderT SimCfg IO ()
type Gateway = StateT GWState (ReaderT SimCfg IO) ()
type Node = StateT NodeState (ReaderT SimCfg IO) ()

log' :: MonadIO m => String -> m ()
log' msg = liftIO $ do
  now <- getCurrentTime
  let ds = formatTime defaultTimeLocale "%Y/%m/%d %H:%M:%S.%3q" now
  putStrLn $ ds ++ " :: " ++ msg

slotToDelay :: (MonadReader SimCfg m, MonadIO m) => Int -> m ()
slotToDelay i = do
  slotLengthMs <- asks _slotLengthMs
  liftIO . threadDelay $ 1000 * slotLengthMs * i

node :: SlotId -> GWChan -> NodeChan -> App
node i ichan ochan = do
  let rng = snd . next . mkStdGen $ (i :: Int)
  log' $ "Node " ++ show i ++ " starting"
  iterateM_ (execStateT go) (NodeState rng)
  where
    go :: Node
    go = do
      g <- gets _rng
      msg <- channelRead ichan
      log' $ "Node  " ++ show i ++ " received message: " ++ show msg
      let (rv :: Int, g') = randomR (0, 100) g
      modify . const $ NodeState g'
      when (rv >= 50) $ do  -- with probability 0.5
        slotToDelay $ i + 1 -- wait for node slot
        channelWrite ochan $ NodeMsg i -- respond back to gateway
    channelWrite ch msg = liftIO $ atomically $ writeTQueue ch msg
    channelRead ch = liftIO $ atomically $ readTQueue ch

gateway :: [NodeChan] -> [GWChan] -> App
gateway ichans ochan = do
  cfg <- ask
  log' "Gateway starting"
  delay <- liftIO $ newDelay $ 1000 * _slotLengthMs cfg * _numNodes cfg
  iterateM_ (execStateT go) (GWState delay)
  where
    go :: Gateway
    go = do
      cfg <- ask
      tm <- gets _timer
      msg <- liftIO $ atomically $ readMany ichans tm
      case msg of
        Timeout -> do
          log' "Gateway Tx window starting"
          writeMany ochan GWMsg
          slotToDelay 1 -- wait for duration of one slot
          log' "Gateway Rx window starting"
          d' <- liftIO $ newDelay $ 1000 * _slotLengthMs cfg * _numNodes cfg
          modify . const $ GWState d' -- reset timeout
        NodeMsg _ -> log' $ "Gateway received message : " ++ show msg
    readMany ch tm =
      foldr (orElse . readTQueue) (waitDelay tm >> pure Timeout) ch
    writeMany chs msg = liftIO . atomically $ mapM_ (`writeTQueue` msg) chs

parseArgs :: [String] -> SimCfg
parseArgs args =
  let numNodes = read <$> headMay args
      slotLengthMs = read <$> (tailMay args >>= headMay)
   in SimCfg (fromMaybe 9 numNodes) (fromMaybe 1000 slotLengthMs)

main :: IO ()
main = do
  cfg <- parseArgs <$> getArgs
  let nm = _numNodes cfg
      createChannels n = replicateM n newTQueueIO
  gwChans <- createChannels nm
  epChans <- createChannels nm
  -- spawn nodes
  mapM_ (forkIO . (`runReaderT` cfg)) $ zipWith3 node [0 ..] gwChans epChans
  -- create gateway
  runReaderT (gateway epChans gwChans) cfg
