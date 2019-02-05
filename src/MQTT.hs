{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module MQTT where

import           Data.Aeson as JSON
import           Data.String.Conversions
import qualified Data.List as L
import           Data.Maybe
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as B
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Monad (unless, forever)
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Except (throwError, runExceptT)
import           System.IO (hPutStrLn, stderr)
import           System.Log.Logger
import           Waziup.Types
import           Waziup.Utils
import           Orion as O hiding (info, warn, debug, err)
import           Waziup.Devices hiding (info, warn, debug, err)
import           Network.MQTT.Client hiding (info, warn, debug, err)
import qualified Network.MQTT.Types as T
import           Database.MongoDB as DB
import           Conduit
import           Data.Conduit.Network
import           Data.Word8           (toUpper)
import           Control.Concurrent.Async (concurrently)
import           Data.Conduit.Attoparsec (conduitParser, sinkParser)
import           Data.Attoparsec.ByteString
import           Keycloak as KC hiding (info, warn, debug, err, Scope) 
import           Servant.Server.Internal.Handler


mqttProxy :: WaziupInfo -> IO ()
mqttProxy wi = do
  runTCPServer (serverSettings 4002 "*") handleClient where
    handleClient :: AppData -> IO ()
    handleClient client = runTCPClient (clientSettings 1883 "localhost") (handleServer wi client) where

handleServer :: WaziupInfo -> AppData -> AppData -> IO ()
handleServer wi clientData serverData = do
  perms <- atomically $ newTVar []
  void $ concurrently
              (runConduit $ appSource serverData .| appSink clientData)
              (runConduit $ appSource clientData .| filterMQTT wi perms .| appSink serverData)
  putStrLn "fun"

displayMQTT :: ConduitT B.ByteString B.ByteString IO ()
displayMQTT = iterMC (putStrLn . show . parse T.parsePacket) 

filterMQTT :: WaziupInfo -> TVar [Perm] -> ConduitT B.ByteString B.ByteString IO ()
filterMQTT wi perms = filterMC $ \p ->  do
  let res = parse T.parsePacket p
  case res of 
    Done _ m -> do
       res <- runExceptT $ runHandler' $ runReaderT (authMQTT m perms) wi
       case res of
         Right b -> return b
         Left e -> error "Error"
    _ -> return True
  

authMQTT :: T.MQTTPkt -> TVar [Perm] -> Waziup Bool
authMQTT (T.ConnPkt (T.ConnectRequest user pass _ _ _ _)) tperms = do
  debug $ "Connect with user: " ++ (show user)
  (WaziupInfo _ (WaziupConfig _ _ keyconf _) _) <- ask 
  if isJust user && isJust pass
    then do
      tok <- runKeycloak $ getUserAuthToken (convertString $ fromJust user) (convertString $ fromJust pass)
      perms <- getPerms (Just tok)
      debug $ "Perms: " ++ (show perms)
      liftIO $ atomically $ writeTVar tperms perms
      return True
    else do
      return True
authMQTT (T.PublishPkt (T.PublishRequest _ _ _ topic _ _)) tperms = do
  info $ "Topic: " ++ (show topic)
  perms <- liftIO $ atomically $ readTVar tperms
  case T.split (== '/') (convertString topic) of
    ["devices", d, "sensors", s, "value"] -> do
      let res = checkPermDevice DevicesDataCreate perms (DeviceId d)
      debug $ "Perm check: " ++ (show res)
      return res
    ["devices", d, "actuators", s, "value"] -> do
      return $ checkPermDevice DevicesDataCreate perms (DeviceId d)
    _ -> return False
authMQTT _ _ = return True


senTopic, actTopic :: Topic
senTopic = "devices/+/sensors/+/value"
actTopic = "devices/+/actuators/+/value"


mqttClient :: WaziupInfo -> IO ()
mqttClient wi = do
  pubChan <- newTChanIO
  mc <- runClient mqttConfig {_msgCB  = Just (handleMsg pubChan),
                              _connID = "sub"}
  res <- subscribe mc [(senTopic, QoS0), (actTopic, QoS0)]
  case res of
    [Just QoS0, Just QoS0] -> forkIO $ forever $ readMsg pubChan wi
    _ -> error "Subscribe failed"
  res <- waitForClient mc   -- wait for the the client to disconnect
  err $ "MQTT client terminated:" ++ (show res)

handleMsg :: TChan (Topic, BL.ByteString) -> MQTTClient -> Topic -> BL.ByteString -> IO ()
handleMsg tc mq topic payload = atomically $ writeTChan tc (topic, payload)

readMsg :: TChan (Topic, BL.ByteString) -> WaziupInfo -> IO ()
readMsg tc wi = do
  (topic, payload) <- liftIO $ atomically $ readTChan tc
  case T.split (== '/') topic of
    ["devices", d, "sensors", s, "value"] -> do
       case (decode $ convertString payload) of
         Just val -> runReaderT (postSensorValue (DeviceId d) (SensorId s) val) wi
         Nothing -> err "not a sensor value"
    ["devices", d, "actuators", s, "value"] -> do
       case (decode $ convertString payload) of
         Just val -> runReaderT (putActuatorValue (DeviceId d) (ActuatorId s) val) wi
         Nothing -> err "not an actuator value"

-- Post sensor value to DBs
-- TODO: access control
postSensorValue :: DeviceId -> SensorId -> SensorValue -> ReaderT WaziupInfo IO ()
postSensorValue did sid senVal@(SensorValue v ts dr) = do 
  info $ convertString $ "Post device " <> (unDeviceId did) <> ", sensor " <> (unSensorId sid) <> ", value: " <> (convertString $ show senVal)
  (WaziupInfo pipe (WaziupConfig _ _ _ conf) _) <- ask
  eent <- liftIO $ runExceptT $ runReaderT (O.getEntity $ toEntityId did) conf
  case eent of 
    Right ent -> do
      let mdevice = getDeviceFromEntity ent
      case L.find (\s -> (senId s) == sid) (devSensors $ fromJust mdevice) of
          Just sensor -> do
            liftIO $ runExceptT $ runReaderT (O.postAttribute (toEntityId did) $ getAttFromSensor (sensor {senValue = Just senVal})) conf
            liftIO $ access pipe DB.master "waziup" (postDatapoint $ Datapoint did sid v ts dr)
            return ()
          Nothing -> do 
            err "sensor not found"
    Left e -> err "Orion error"

putActuatorValue :: DeviceId -> ActuatorId ->JSON.Value -> ReaderT WaziupInfo IO ()
putActuatorValue did aid actVal = do
  info $ convertString $ "Post device " <> (unDeviceId did) <> ", actuator " <> (unActuatorId aid) <> ", value: " <> (convertString $ show actVal)
  (WaziupInfo pipe (WaziupConfig _ _ _ conf) _) <- ask
  eent <- liftIO $ runExceptT $ runReaderT (O.getEntity $ toEntityId did) conf
  case eent of 
    Right ent -> do
      let mdevice = getDeviceFromEntity ent
      case L.find (\a -> (actId a) == aid) (devActuators $ fromJust mdevice) of
          Just act -> do
            liftIO $ runExceptT $ runReaderT (O.postAttribute (toEntityId did) $ getAttFromActuator (act {actValue = Just actVal})) conf
            return ()
          Nothing -> do 
            err "actuator not found"
    Left e -> err "Orion error"

publishSensorValue :: DeviceId -> SensorId -> SensorValue -> IO ()
publishSensorValue (DeviceId d) (SensorId s) v = do
  let topic = "devices/" <> d <> "/sensors/" <> s <> "/value"
  mc <- runClient mqttConfig { _connID = "pub"}
  info $ "Publish sensor value: " ++ (convertString $ encode v) ++ " to topic: " ++ (show topic)
  publish mc topic (convertString $ encode v) False

-- Logging
warn, info, debug, err :: (MonadIO m) => String -> m ()
debug s = liftIO $ debugM   "MQTT" s
info  s = liftIO $ infoM    "MQTT" s
warn  s = liftIO $ warningM "MQTT" s
err   s = liftIO $ errorM   "MQTT" s
