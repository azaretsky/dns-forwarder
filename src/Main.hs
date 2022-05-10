module Main (main) where

import Control.Concurrent
import Control.Exception (bracket)
import Control.Monad (forever, void, when)
import qualified Data.ByteString as B
import qualified Data.Map as M
import Foreign hiding (void)
import Network.Socket
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
        forkIO_ $ do
            response <- query targetAI request
            void $ sendTo serverSocket response clientAddress
            return ()

data Task = Submit B.ByteString SockAddr | Dispatch Word32 B.ByteString

receiver :: HostName -> ServiceName -> IO ()
receiver bindHost bindService = do
    bindAI <- lookupAddress bindHost bindService
    withBoundSocketForAddress bindAI $ \serverSocket -> do
        submitRequest <- spawnSubmitter
        tasks <- newChan
        let processTasks requestId addrs = do
                task <- readChan tasks
                case task of
                    Submit request clientAddress -> do
                        submitRequest requestId request
                        processTasks (requestId + 1) (M.insert requestId clientAddress addrs)
                    Dispatch responseId response -> do
                        let (c, addrs') = M.updateLookupWithKey (\_ _ -> Nothing) responseId addrs
                        case c of
                            Nothing -> hPutStrLn stderr ("unknown response id " ++ show responseId)
                            Just clientAddress -> forkIO_ $ void $ sendTo serverSocket response clientAddress
                        processTasks requestId addrs'
        forkIO_ $ processTasks 0 M.empty
        forkIO_ $ pullPdus $ \responseId response -> writeChan tasks $ Dispatch responseId response
        forever $ do
            (request, clientAddress) <- recvFrom serverSocket maxDatagramSize
            writeChan tasks $ Submit request clientAddress

transmitter :: HostName -> ServiceName -> IO ()
transmitter targetHost targetService = do
    targetAI <- lookupAddress targetHost targetService
    submitResponse <- spawnSubmitter
    pullPdus $ \requestId request ->
        forkIO_ $ query targetAI request >>= submitResponse requestId

query :: AddrInfo -> B.ByteString -> IO B.ByteString
query targetAI request = withSocketForAddress targetAI $ \targetSocket -> do
    connect targetSocket (addrAddress targetAI)
    void $ send targetSocket request
    recv targetSocket maxDatagramSize

headerLength :: Int
headerLength = 6

pullPdus :: (Word32 -> B.ByteString -> IO ()) -> IO ()
pullPdus handler = allocaBytes headerLength $ \buf -> forever $ do
    headerSize <- hGetBuf stdin buf headerLength
    when (headerSize < headerLength) $ fail "end of input"
    pduId <- peek (castPtr buf)
    lenHigh <- peek (plusPtr buf 4) :: IO Word8
    lenLow <- peek (plusPtr buf 5) :: IO Word8
    let pduLength = fromIntegral lenHigh `shiftL` 8 .|. fromIntegral lenLow
    pdu <- B.hGet stdin pduLength
    when (B.length pdu < pduLength) $ fail "truncated pdu"
    handler pduId pdu

spawnSubmitter :: IO (Word32 -> B.ByteString -> IO ())
spawnSubmitter = do
    chan <- newChan
    forkIO_ $ allocaBytes headerLength $ \buf -> forever $ do
        (pduId, pdu) <- readChan chan
        poke (castPtr buf) pduId
        let pduLength = B.length pdu
        poke (plusPtr buf 4) (fromIntegral (pduLength `shiftR` 8 .&. 0xff) :: Word8)
        poke (plusPtr buf 5) (fromIntegral (pduLength .&. 0xff) :: Word8)
        hPutBuf stdout buf headerLength
        B.hPut stdout pdu
        hFlush stdout
    return $ curry (writeChan chan)

forkIO_ :: IO () -> IO ()
forkIO_ = void . forkIO

lookupAddress :: HostName -> ServiceName -> IO AddrInfo
lookupAddress host service = do
    ais <- getAddrInfo (Just defaultHints {addrFlags = [AI_ADDRCONFIG, AI_V4MAPPED], addrSocketType = Datagram}) (Just host) (Just service)
    case ais of
        [] -> fail ("could not obtain address information for host " ++ host ++ " and service " ++ service)
        (ai : _) -> return ai

withSocketForAddress :: AddrInfo -> (Socket -> IO a) -> IO a
withSocketForAddress ai f = bracket (socket (addrFamily ai) (addrSocketType ai) (addrProtocol ai)) close f

withBoundSocketForAddress :: AddrInfo -> (Socket -> IO ()) -> IO ()
withBoundSocketForAddress ai f = withSocketForAddress ai $ \s -> do
    bind s (addrAddress ai)
    f s
