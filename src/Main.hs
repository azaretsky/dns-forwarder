module Main (main) where

import Control.Concurrent
import Control.Exception (bracket)
import Control.Monad (forever, when)
import qualified Data.ByteString as B
import qualified Data.Map as M
import Data.Word (Word8, Word32)
import Foreign
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString (send, sendTo, recv, recvFrom)
import System.Environment (getArgs)
import System.IO

maxDatagramSize :: Int
maxDatagramSize = 2048

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["simple", bindHost, bindService, targetHost, targetService] ->
            simple bindHost bindService targetHost targetService
        ["receiver", bindHost, bindService] -> receiver bindHost bindService
        ["transmitter", targetHost, targetService] -> transmitter targetHost targetService
        _ -> fail ("don't know what to do with " ++ show args)

simple :: HostName -> ServiceName -> HostName -> ServiceName -> IO ()
simple bindHost bindService targetHost targetService = do
    bindAI <- lookupAddress bindHost bindService
    targetAI <- lookupAddress targetHost targetService
    withBoundSocketForAddress bindAI $ \serverSocket -> forever $ do
        (request, clientAddress) <- recvFrom serverSocket maxDatagramSize
        forkIO $ withConnectedSocketForAddress targetAI $ \targetSocket -> do
            _ <- send targetSocket request
            response <- recv targetSocket maxDatagramSize
            _ <- sendTo serverSocket response clientAddress
            return ()

headerLength :: Int
headerLength = 6

withHeaderBuf :: (Ptr () -> IO ()) -> IO ()
withHeaderBuf = allocaBytes headerLength

receiver :: HostName -> ServiceName -> IO ()
receiver bindHost bindService = do
    bindAI <- lookupAddress bindHost bindService
    conts <- newMVar M.empty
    requests <- newChan
    let submitLoop requestId buf = do
            (request, cont) <- readChan requests
            modifyMVar_ conts $ return . M.insert requestId cont
            submitPdu buf requestId request
            submitLoop (requestId + 1) buf
    _ <- forkIO $ withHeaderBuf $ submitLoop 0
    _ <- forkIO $ withHeaderBuf $ \buf -> forever $ do
        (responseId, response) <- receivePdu buf
        maybeCont <- modifyMVar conts $ \m -> (\(c, m') -> return (m', c)) $ M.updateLookupWithKey (\_ _ -> Nothing) responseId m
        case maybeCont of
            Nothing -> hPutStrLn stderr ("unknown response id " ++ show responseId)
            Just cont -> forkIO (cont response) >> return ()
    withBoundSocketForAddress bindAI $ \serverSocket -> forever $ do
        (request, clientAddress) <- recvFrom serverSocket maxDatagramSize
        writeChan requests (request, \response -> sendTo serverSocket response clientAddress >> return ())

transmitter :: HostName -> ServiceName -> IO ()
transmitter targetHost targetService = do
    targetAI <- lookupAddress targetHost targetService
    responses <- newChan
    _ <- forkIO $ withHeaderBuf $ \buf -> forever $ do
        (requestId, response) <- readChan responses
        submitPdu buf requestId response
    withHeaderBuf $ \buf ->
        forever $ do
            (requestId, request) <- receivePdu buf
            forkIO $ withConnectedSocketForAddress targetAI $ \targetSocket -> do
                _ <- send targetSocket request
                response <- recv targetSocket maxDatagramSize
                writeChan responses (requestId, response)

receivePdu :: Ptr () -> IO (Word32, B.ByteString)
receivePdu buf = do
    headerSize <- hGetBuf stdin buf headerLength
    when (headerSize < headerLength) $ fail "end of input"
    pduId <- peek (castPtr buf)
    lenHigh <- peek (plusPtr buf 4) :: IO Word8
    lenLow <- peek (plusPtr buf 5) :: IO Word8
    let pduLength = fromIntegral lenHigh `shiftL` 8 .|. fromIntegral lenLow
    pdu <- B.hGet stdin pduLength
    when (B.length pdu < pduLength) $ fail "truncated pdu"
    return (pduId, pdu)

submitPdu :: Ptr () -> Word32 -> B.ByteString -> IO ()
submitPdu buf pduId pdu = do
    poke (castPtr buf) pduId
    let pduLength = B.length pdu
    poke (plusPtr buf 4) (fromIntegral (pduLength `shiftR` 8 .&. 0xff) :: Word8)
    poke (plusPtr buf 5) (fromIntegral (pduLength .&. 0xff) :: Word8)
    hPutBuf stdout buf headerLength
    B.hPut stdout pdu
    hFlush stdout

lookupAddress :: HostName -> ServiceName -> IO AddrInfo
lookupAddress host service = do
    ais <- getAddrInfo (Just defaultHints {addrFlags = [AI_ADDRCONFIG, AI_V4MAPPED], addrSocketType = Datagram}) (Just host) (Just service)
    case ais of
        [] -> fail ("could not obtain address information for host " ++ host ++ " and service " ++ service)
        (ai : _) -> return ai

withSocketForAddress :: AddrInfo -> (Socket -> IO ()) -> IO ()
withSocketForAddress ai f = bracket (socket (addrFamily ai) (addrSocketType ai) (addrProtocol ai)) close f

withBoundSocketForAddress :: AddrInfo -> (Socket -> IO ()) -> IO ()
withBoundSocketForAddress ai f = withSocketForAddress ai $ \s -> do
    bind s (addrAddress ai)
    f s

withConnectedSocketForAddress :: AddrInfo -> (Socket -> IO ()) -> IO ()
withConnectedSocketForAddress ai f = withSocketForAddress ai $ \s -> do
    connect s (addrAddress ai)
    f s
