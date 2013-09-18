{-# LANGUAGE OverloadedStrings #-}

-- | Basic support for encrypted PDF documents

module Pdf.Toolbox.Document.Encryption
(
  Decryptor,
  defaultUserPassword,
  mkStandardDecryptor,
  decryptObject
)
where

import Data.Bits (xor)
import Data.IORef
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Lazy.Builder
import Control.Monad
import qualified System.IO.Streams as Streams
import qualified Crypto.Cipher.RC4 as RC4
import qualified Crypto.Hash.MD5 as MD5

import Pdf.Toolbox.Core

-- | Decrypt input stream
type Decryptor = Ref -> IS -> IO IS

-- | Decrypt object with the decryptor
decryptObject :: (IS -> IO IS) -> Object a -> IO (Object a)
decryptObject decryptor (OStr str) = OStr `liftM` decryptStr decryptor str
decryptObject decryptor (ODict dict) = ODict `liftM` decryptDict decryptor dict
decryptObject _ o = return o

decryptStr :: (IS -> IO IS) -> Str -> IO Str
decryptStr decryptor (Str str) = do
  is <- Streams.fromList [str]
  res <- decryptor is >>= Streams.toList
  return $ Str $ BS.concat res

decryptDict :: (IS -> IO IS) -> Dict -> IO Dict
decryptDict decryptor (Dict vals) = Dict `liftM` forM vals decr
  where
  decr (key, val) = do
    res <- decryptObject decryptor val
    return (key, res)

-- | The default user password
defaultUserPassword :: ByteString
defaultUserPassword = BS.pack [
  0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E,
  0x56, 0xFF, 0xFA, 0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68,
  0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A
  ]

-- | Standard decryptor. RC4
mkStandardDecryptor :: Monad m
                    => Dict            -- ^ document trailer
                    -> Dict            -- ^ encryption dictionary
                    -> ByteString      -- ^ user password (32 bytes exactly, see 7.6.3.3 Encryption Key Algorithm)
                    -> PdfE m (Maybe Decryptor)
mkStandardDecryptor tr enc pass = do
  Name filterType <- lookupDict "Filter" enc >>= fromObject
  unless (filterType == "Standard") $ left $ UnexpectedError $ "Unsupported encryption handler: " ++ show filterType
  vVal <- lookupDict "V" enc >>= fromObject >>= intValue
  n <- case vVal of
         1 -> return 5
         2 -> do
           len <- lookupDict "Length" enc >>= fromObject >>= intValue
           return $ len `div` 8
         _ -> left $ UnexpectedError $ "Unsuported encryption handler version: " ++ show vVal
  Str oVal <- lookupDict "O" enc >>= fromObject
  pVal <- (BS.pack . BSL.unpack . toLazyByteString . word32LE . fromIntegral)
    `liftM` (lookupDict "P" enc >>= fromObject >>= intValue)
  Str idVal <- do
    Array ids <- lookupDict "ID" tr >>= fromObject
    case ids of
      [] -> left $ UnexpectedError $ "ID array is empty"
      (x:_) -> fromObject x
  let ekey' = BS.take n $ MD5.hash $ BS.concat [pass, oVal, pVal, idVal]
  rVal <- lookupDict "R" enc >>= fromObject >>= intValue
  let ekey = if rVal < 3
               then ekey'
               else foldl (\bs _ -> BS.take n $ MD5.hash bs) ekey'  [1 :: Int .. 50]

  Str uVal <- lookupDict "U" enc >>= fromObject
  let ok =
        case rVal of
          2 ->
            let uVal' = snd $ RC4.combine (RC4.initCtx ekey) defaultUserPassword
            in uVal == uVal'
          _ ->
            let pass1 = snd $ RC4.combine (RC4.initCtx ekey) $ BS.take 16 $ MD5.hash $ BS.concat [defaultUserPassword, idVal]
                uVal' = loop 1 pass1
                loop 20 input = input
                loop i input = loop (i + 1) $ snd $ RC4.combine (RC4.initCtx $ BS.map (`xor` i) ekey) input
            in BS.take 16 uVal == BS.take 16 uVal'

  let decryptor = \(Ref index gen) is -> do
        let key = BS.take (16 `min` n + 5) $ MD5.hash $ BS.concat [
              ekey,
              BS.pack $ take 3 $ BSL.unpack $ toLazyByteString $ int32LE $ fromIntegral index,
              BS.pack $ take 2 $ BSL.unpack $ toLazyByteString $ int32LE $ fromIntegral gen
              ]
            ctx = RC4.initCtx key
        ioRef <- newIORef ctx
        let readNext = do
              chunk <- Streams.read is
              case chunk of
                Nothing -> return Nothing
                Just c -> do
                  ctx' <- readIORef ioRef
                  let (ctx'', res) = RC4.combine ctx' c
                  writeIORef ioRef ctx''
                  return (Just res)
        Streams.makeInputStream readNext

  if ok
    then return $ Just decryptor
    else return Nothing
