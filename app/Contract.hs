module Contract
  ( Contract(..)
  , Channel(..)
  , PayloadFormat(..)
  , Keyable(..)
  , Direction(..)
  , ClaimsBlob(..)
  , symmetricalChannel
  , retrievePayload
  ) where

import Protolude               (($), Either(..), IO, return, Maybe(..), Show)
import Data.ByteString         (ByteString)
import Jose.Jwk                (Jwk)
import Jose.Jwa                (JweAlg, Enc, JwsAlg)
import Jose.Jwe                (jwkDecode)
import Jose.Jwt                (JwtContent(..), JwtError(..), JwtEncoding(..))

import qualified Jose.Jwt as   Jwt

class Keyable a where
  retrieveKey :: a -> Jwk


data (Keyable s, Keyable r) => Contract s r
  = Contract
  { payloadFormat :: PayloadFormat
  , sender        :: s
  , recipient     :: r
  }

data (Keyable e1, Keyable e2) => Channel e1 e2
  = Channel
  { outgoing :: Contract e1 e2
  , incoming :: Contract e2 e1
  }

data PayloadFormat
  = WrappedJwt JwsAlg JweAlg Enc


data Direction
  = Incoming
  | Outgoing

data PayloadError
  = JwtErr JwtError
  | IncorrectFormatError
  deriving (Show)

newtype ClaimsBlob = ClaimsBlob ByteString

symmetricalChannel :: (Keyable sender, Keyable recipient) => sender -> recipient -> PayloadFormat -> Channel sender recipient
symmetricalChannel s r form = Channel sendingContract receivingContract where
    sendingContract   = Contract form s r
    receivingContract = Contract form r s

retrievePayload :: (Keyable s, Keyable r) => Channel s r -> Direction -> ByteString -> IO (Either PayloadError ClaimsBlob)
retrievePayload channel direction =
  let
    unpack :: (Keyable s, Keyable r) => Contract s r -> ByteString -> IO (Either PayloadError ClaimsBlob)
    unpack contract input = case payloadFormat contract of
      WrappedJwt jwsAlg _ _ -> do
        let recipientKey = retrieveKey $ recipient contract
        result <- jwkDecode recipientKey input
        case result of
          Right (Unsecured content) -> decodeAndUnpackJwt (retrieveKey $ sender contract) jwsAlg content
          Right _                   -> return $ Left IncorrectFormatError
          Left err                  -> return $ Left $ JwtErr err
  in
  case direction of
    Incoming -> unpack $ incoming channel
    Outgoing -> unpack $ outgoing channel

decodeAndUnpackJwt :: Jwk -> JwsAlg -> ByteString -> IO (Either PayloadError ClaimsBlob)
decodeAndUnpackJwt key alg input = do
  result <- Jwt.decode [key] (Just $ JwsEncoding alg) input
  return $ case result of
    Right (Jws (_, claimsBlob)) -> Right $ ClaimsBlob claimsBlob
    Right _                     -> Left IncorrectFormatError
    Left err                    -> Left $ JwtErr err
