{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Waziup.Server where

import           Waziup.Types
import           Waziup.API
import           Waziup.Devices
import           Waziup.Ontologies
import           Waziup.Projects
import           Waziup.Sensors
import           Waziup.SensorData
import qualified Keycloak.Types as KC
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Lens hiding ((.=))
import           Data.Proxy (Proxy(..))
import qualified Data.Swagger as S
import qualified Data.ByteString.Lazy as BL
import           Data.Set
import           Servant
import           Servant.Server
import           Servant.Swagger
import           Servant.Swagger.UI
import           System.Log.Logger

-- * Building the server

server :: ServerT API Waziup
server = serverWaziup
    :<|> serverDocs

serverWaziup :: ServerT WaziupAPI Waziup
serverWaziup = authServer
          :<|> devicesServer
          :<|> sensorsServer
          :<|> actuatorsServer
          :<|> sensorDataServer
          :<|> gatewaysServer
          :<|> projectsServer
          :<|> usersServer
          :<|> ontologiesServer

serverDocs :: ServerT WaziupDocs Waziup
serverDocs = hoistDocs $ swaggerSchemaUIServer swaggerDoc

authServer :: ServerT AuthAPI Waziup
authServer = getPerms
        :<|> postAuth

devicesServer :: ServerT DevicesAPI Waziup
devicesServer = getDevices
           :<|> postDevice
           :<|> getDevice
           :<|> deleteDevice
           :<|> putDeviceName
           :<|> putDeviceLocation
           :<|> putDeviceGatewayId
           :<|> putDeviceVisibility

sensorsServer :: ServerT SensorsAPI Waziup
sensorsServer = getSensors
           :<|> postSensor
           :<|> getSensor
           :<|> deleteSensor
           :<|> putSensorName
           :<|> putSensorSensorKind
           :<|> putSensorQuantityKind
           :<|> putSensorUnit
           :<|> putSensorCalib
           :<|> putSensorValue

sensorDataServer :: ServerT SensorDataAPI Waziup
sensorDataServer = getDatapoints

gatewaysServer :: ServerT GatewaysAPI Waziup
gatewaysServer = error "Not yet implemented"

actuatorsServer :: ServerT ActuatorsAPI Waziup
actuatorsServer = error "Not yet implemented"

usersServer :: ServerT UsersAPI Waziup
usersServer = error "Not yet implemented"

projectsServer :: ServerT ProjectsAPI Waziup
projectsServer = getProjects
            :<|> postProject
            :<|> getProject
            :<|> deleteProject
            :<|> putProjectDevices
            :<|> putProjectGateways

ontologiesServer :: ServerT OntologiesAPI Waziup
ontologiesServer = getSensorKinds
              :<|> getActuatorKinds
              :<|> getQuantityKinds
              :<|> getUnits

-- final server
waziupServer :: WaziupInfo -> Application
waziupServer conf = serve waziupAPI $ Servant.Server.hoistServer waziupAPI (getHandler conf) server

-- Swagger docs
swaggerDoc :: S.Swagger
swaggerDoc = toSwagger (Proxy :: Proxy WaziupAPI)
  & S.info . S.title       .~ "Waziup API"
  & S.info . S.version     .~ "v2.0.0"
  & S.info . S.description ?~ "This API allows you to access all Waziup services.\n\
                              \In order to access protected services, first get a token with POST /auth/token.\n\
                              \Then insert this token in the authorization key, specifying “Bearer” in front. For example \"Bearer eyJhbGc…\"."
  & S.basePath ?~ "/api/v2"
  & S.applyTagsFor devicesOps ["Devices"]
  & S.applyTagsFor sensorOps  ["Sensors"]
  & S.applyTagsFor actuatOps  ["Actuators"]
  & S.applyTagsFor dataOps    ["Sensor Data"]
  & S.applyTagsFor authOps    ["Auth"]
  & S.applyTagsFor projectOps ["Projects"]
  & S.applyTagsFor userOps    ["Users"]
  & S.applyTagsFor ontoOps    ["Ontologies"]
  & S.applyTagsFor gwsOps     ["Gateways"]
  & S.tags .~ (fromList [])
  where
    devicesOps, sensorOps, actuatOps, dataOps, authOps, projectOps, userOps, ontoOps, gwsOps :: Traversal' S.Swagger S.Operation
    devicesOps = subOperations (Proxy :: Proxy DevicesAPI)    (Proxy :: Proxy WaziupAPI)
    sensorOps  = subOperations (Proxy :: Proxy SensorsAPI)    (Proxy :: Proxy WaziupAPI)
    actuatOps  = subOperations (Proxy :: Proxy ActuatorsAPI)  (Proxy :: Proxy WaziupAPI)
    dataOps    = subOperations (Proxy :: Proxy SensorDataAPI) (Proxy :: Proxy WaziupAPI)
    authOps    = subOperations (Proxy :: Proxy AuthAPI)       (Proxy :: Proxy WaziupAPI)
    projectOps = subOperations (Proxy :: Proxy ProjectsAPI)   (Proxy :: Proxy WaziupAPI)
    userOps    = subOperations (Proxy :: Proxy UsersAPI)      (Proxy :: Proxy WaziupAPI)
    ontoOps    = subOperations (Proxy :: Proxy OntologiesAPI) (Proxy :: Proxy WaziupAPI)
    gwsOps     = subOperations (Proxy :: Proxy GatewaysAPI)   (Proxy :: Proxy WaziupAPI)

-- * helpers

waziupAPI :: Proxy API
waziupAPI = Proxy

getHandler :: WaziupInfo -> Waziup a -> Servant.Handler a
getHandler s x = runReaderT x s

hoistDocs :: ServerT WaziupDocs Servant.Handler -> ServerT WaziupDocs Waziup
hoistDocs s = Servant.Server.hoistServer (Proxy :: Proxy WaziupDocs) lift s


-- Logging
warn, info, debug, err :: (MonadIO m) => String -> m ()
debug s = liftIO $ debugM "API" s
info  s = liftIO $ infoM "API" s
warn  s = liftIO $ warningM "API" s
err   s = liftIO $ errorM "API" s

instance MimeRender PlainText KC.Token where
  mimeRender _ (KC.Token tok) = BL.fromStrict tok
