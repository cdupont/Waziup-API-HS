{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Keycloak.Types where

import Data.Aeson as JSON
import Data.Aeson.Types
import Data.Aeson.Casing
import Data.Text hiding (head, tail, map, toLower)
import Data.Text.Encoding
import GHC.Generics (Generic)
import Data.Maybe
import Data.Aeson.BetterErrors as AB
import Web.HttpApiData (FromHttpApiData(..), ToHttpApiData(..))
import Network.HTTP.Client as HC hiding (responseBody)
import Data.Monoid
import Control.Monad.Except (ExceptT)
import Control.Monad.Reader as R
import qualified Data.ByteString as BS
import Data.Word8 (isSpace, _colon, toLower)

type Keycloak a = ReaderT KCConfig (ExceptT KCError IO) a

data KCError = HTTPError HttpException  -- ^ Keycloak returned an HTTP error.
             | ParseError Text          -- ^ Failed when parsing the response
             | EmptyError               -- ^ Empty error to serve as a zero element for Monoid.

data KCConfig = KCConfig {
  baseUrl       :: Text,
  realm         :: Text,
  clientId      :: Text,
  clientSecret  :: Text,
  adminLogin    :: Text,
  adminPassword :: Text,
  guestLogin    :: Text,
  guestPassword :: Text} deriving (Eq, Show)

defaultKCConfig :: KCConfig
defaultKCConfig = KCConfig {
  baseUrl       = "http://localhost:8080/auth",
  realm         = "waziup",
  clientId      = "api-server",
  clientSecret  = "4e9dcb80-efcd-484c-b3d7-1e95a0096ac0",
  adminLogin    = "cdupont",
  adminPassword = "password",
  guestLogin    = "guest",
  guestPassword = "guest"}

type Path = Text
newtype Token = Token {unToken :: BS.ByteString} deriving (Eq, Show, Generic)

instance FromHttpApiData Token where
  parseQueryParam = parseHeader . encodeUtf8
  parseHeader (extractBearerAuth -> Just tok) = Right $ Token tok
  parseHeader _ = Left "cannot extract auth Bearer"

extractBearerAuth :: BS.ByteString -> Maybe BS.ByteString
extractBearerAuth bs =
    let (x, y) = BS.break isSpace bs
    in if BS.map toLower x == "bearer"
        then Just $ BS.dropWhile isSpace y
        else Nothing

instance ToHttpApiData Token where
  toQueryParam (Token token) = "Bearer " <> (decodeUtf8 token)

newtype ResourceId = ResourceId {unResId :: Text} deriving (Show, Eq, Generic, ToJSON, FromJSON)
type ResourceName = Text
type ScopeId = Text
type ScopeName = Text
type Scope = Text 

data Permission = Permission 
  { rsname :: ResourceName,
    rsid   :: ResourceId,
    scopes :: [Scope]
  } deriving (Generic, Show)

parsePermission :: Parse e Permission
parsePermission = do
    rsname  <- AB.key "rsname" asText
    rsid    <- AB.key "rsid" asText
    scopes  <- AB.keyMay "scopes" (eachInArray asText) 
    return $ Permission rsname (ResourceId rsid) (if (isJust scopes) then (fromJust scopes) else [])

type Username = Text

data Owner = Owner {
  ownId   :: Maybe Text,
  ownName :: Username
  } deriving (Generic, Show)

instance FromJSON Owner where
  parseJSON = genericParseJSON $ aesonDrop 3 snakeCase 
instance ToJSON Owner where
  toJSON = genericToJSON $ (aesonDrop 3 snakeCase) {omitNothingFields = True}

data Resource = Resource {
     resId      :: Maybe ResourceId,
     resName    :: ResourceName,
     resType    :: Maybe Text,
     resUris    :: [Text],
     resScopes  :: [Scope],
     resOwner   :: Owner,
     resOwnerManagedAccess :: Bool,
     resAttributes :: [Attribute]
  } deriving (Generic, Show)

instance FromJSON Resource where
  parseJSON = genericParseJSON $ aesonDrop 3 camelCase 
instance ToJSON Resource where
  toJSON (Resource id name typ uris scopes own uma attrs) =
    object ["name" .= toJSON name,
            "uris" .= toJSON uris,
            "scopes" .= toJSON scopes,
            "owner" .= toJSON own,
            "ownerManagedAccess" .= toJSON uma,
            "attributes" .= object (map (\(Attribute name vals) -> name .= toJSON vals) attrs)]

data Attribute = Attribute {
  attName   :: Text,
  attValues :: [Text]
  } deriving (Generic, Show)

instance FromJSON Attribute where
  parseJSON = genericParseJSON $ aesonDrop 3 camelCase 
instance ToJSON Attribute where
  toJSON (Attribute name vals) = object [name .= toJSON vals] 


data TokenDec = TokenDec {
  jti :: Text,
  exp :: Int,
  nbf :: Int,
  iat :: Int,
  iss :: Text,
  aud :: Text,
  sub :: Text,
  typ :: Text,
  azp :: Text,
  authTime :: Int,
  sessionState :: Text,
  acr :: Text,
  allowedOrigins :: Value,
  realmAccess :: Value,
  ressourceAccess :: Value,
  scope :: Text,
  name :: Text,
  preferredUsername :: Text,
  givenName :: Text,
  familyName :: Text,
  email :: Text
  } deriving (Generic, Show)

--instance FromJSON TokenDec where
--  parseJSON = genericParseJSON $ aesonDrop 3 camelCase 
--instance ToJSON TokenDec where
--  toJSON = genericToJSON $ (aesonDrop 3 camelCase) {omitNothingFields = True}

parseTokenDec :: Parse e TokenDec
parseTokenDec = TokenDec <$>
    AB.key "jti" asText <*>
    AB.key "exp" asIntegral <*>
    AB.key "nbf" asIntegral <*>
    AB.key "iat" asIntegral <*>
    AB.key "iss" asText <*>
    AB.key "aud" asText <*>
    AB.key "sub" asText <*>
    AB.key "typ" asText <*>
    AB.key "azp" asText <*>
    AB.key "auth_time" asIntegral <*>
    AB.key "session_state" asText <*>
    AB.key "acr" asText <*>
    AB.key "allowed-origins" asValue <*>
    AB.key "realm_access" asValue <*>
    AB.key "resource_access" asValue <*>
    AB.key "scope" asText <*>
    AB.key "name" asText <*>
    AB.key "preferred_username" asText <*>
    AB.key "given_name" asText <*>
    AB.key "family_name" asText <*>
    AB.key "email" asText
