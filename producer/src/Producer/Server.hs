{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Producer.Server where

-- EXTERNAL

import           Control.Monad (forever)
import qualified Control.Retry as Retry
import           Data.Monoid ((<>))
import           Data.Text (Text)
import qualified Network.AMQP as AMQ
import           Network.HTTP.Types (status400)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Handler.WebSockets as WaiWS
import qualified Network.WebSockets as WS

-- INTERNAL

import           Producer.Config
import           Producer.Types

server :: IO ()
server = do
  rabbitConfig <- getRabbitConfig
  attemptTo (setupRabbit rabbitConfig)
  setupWebSocketServer rabbitConfig
  where
    app :: RabbitConfig -> WS.ServerApp
    app =
      handleConnection

    appFallback :: Wai.Application
    appFallback _ respond =
      respond (Wai.responseLBS status400 [] "server only talks websockets")

    attemptTo :: (Retry.RetryStatus -> IO a) -> IO a
    attemptTo =
      Retry.recoverAll (Retry.fibonacciBackoff 500000 <> Retry.limitRetries 10)

    setupRabbit :: RabbitConfig -> a -> IO ()
    setupRabbit rabbitConfig _ = do
      putStrLn "establishing connection with rabbitmq"
      (connection, channel) <- createRabbitChannel rabbitConfig
      _                     <- setupExchange rabbitConfig channel
      _                     <- setupQueue rabbitConfig channel
      AMQ.closeConnection connection

    setupWebSocketServer :: RabbitConfig -> IO ()
    setupWebSocketServer rabbitConfig = do
      WSConfig{..} <- getWsConfig
      serverStarting wsAddress wsPort
      Warp.run wsPort (WaiWS.websocketsOr WS.defaultConnectionOptions (app rabbitConfig) appFallback)

    serverStarting :: String -> Int -> IO ()
    serverStarting address port = putStrLn $
      "server starting on: " <> address <> ":" <> (show port)

--------------------------------------------------------------------------------

-- | Opens a new connection to Rabbit and creates a new channel.
createRabbitChannel :: RabbitConfig -> IO (AMQ.Connection, AMQ.Channel)
createRabbitChannel RabbitConfig{..} = do
  connection <- AMQ.openConnection rabbitAddress "/" rabbitUsername rabbitPassword
  channel    <- AMQ.openChannel connection
  return (connection, channel)

-- | Handles an incoming Websocket connection and publishes incoming messages to
-- the queue.
handleConnection :: RabbitConfig -> WS.ServerApp
handleConnection rabbitConfig@RabbitConfig{..} pendingConnection = do
  connection <- WS.acceptRequest pendingConnection
  _          <- sendGreeting connection
  channel    <- setupChannel
  forever (publishFromWStoRabbit connection channel)
  where
    publishFromWStoRabbit :: WS.Connection -> AMQ.Channel -> IO ()
    publishFromWStoRabbit connection channel = do
      WS.Text message _ <- WS.receiveDataMessage connection
      AMQ.publishMsg channel rabbitExchange rabbitKey $
        AMQ.newMsg { AMQ.msgBody = message, AMQ.msgDeliveryMode = Just AMQ.Persistent }
      return ()

    setupChannel :: IO AMQ.Channel
    setupChannel = do
      (_, channel) <- createRabbitChannel rabbitConfig
      _            <- AMQ.bindQueue channel rabbitQueue rabbitExchange rabbitKey
      return channel

    sendGreeting :: WS.Connection -> IO ()
    sendGreeting connection =
      WS.sendTextData connection ("hello" :: Text)

-- | Sets up new exchange if it doesn't exist.
setupExchange :: RabbitConfig -> AMQ.Channel -> IO ()
setupExchange RabbitConfig{..} channel = do
  AMQ.declareExchange channel exchange
  where
    exchange :: AMQ.ExchangeOpts
    exchange =
      AMQ.newExchange { AMQ.exchangeName = rabbitExchange, AMQ.exchangeType = "direct" }

-- | Sets up new queue if it doesn't exist.
setupQueue :: RabbitConfig -> AMQ.Channel -> IO (Text, Int, Int)
setupQueue RabbitConfig{..} channel = do
  AMQ.declareQueue channel queue
  where
    queue :: AMQ.QueueOpts
    queue =
      AMQ.newQueue { AMQ.queueName = rabbitQueue }
