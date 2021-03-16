module Main (main) where

import Control.Concurrent (forkIO)
import Control.Exception (bracket)
import Control.Monad (forever)
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString (send, sendTo, recv, recvFrom)
import System.Environment (getArgs)

main :: IO ()
main = do
    bindHost : bindService : targetHost : targetService :  _ <- getArgs
    bindAI <- lookupAddress bindHost bindService
    targetAI <- lookupAddress targetHost targetService
    withBoundSocketForAddress bindAI $ \serverSocket -> forever $ do
        (request, clientAddress) <- recvFrom serverSocket 2048
        forkIO $ withConnectedSocketForAddress targetAI $ \targetSocket -> do
            _ <- send targetSocket request
            response <- recv targetSocket 2048
            _ <- sendTo serverSocket response clientAddress
            return ()

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
