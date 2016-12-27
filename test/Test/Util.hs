{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecursiveDo           #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}

module Test.Util
       ( Parcel (..)

       , TestState (..)
       , mkTestState
       , expected
       , fails
       , activeWorkers
       , modifyTestState
       , addFail
       , newWork

       , TalkStyle (..)
       , sendAll
       , receiveAll

       , deliveryTest
       ) where

import           Control.Concurrent.STM      (STM, atomically, check)
import           Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, writeTVar)
import           Control.Exception           (Exception, SomeException (..))
import           Control.Lens                (makeLenses, (%=), (-=))
import           Control.Monad               (forM_, void)
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.State         (StateT)
import           Data.Binary                 (Binary)
import           Data.Foldable               (for_)
import qualified Data.List                   as L
import qualified Data.Set                    as S
import           Data.Void                   (Void)
import           GHC.Generics                (Generic)
import           Mockable.Concurrent         (delay, fork)
import           Mockable.Exception          (catch, throw)
import           Mockable.Production         (Production (..))
import           Network.Transport.Abstract  (closeTransport, newEndPoint)
import           Network.Transport.Concrete  (concrete)
import qualified Network.Transport.TCP       as TCP
import           Node                        (ConversationActions (..), Listener (..),
                                              ListenerAction (..), MessageName, NodeId,
                                              PreListener, SendActions (..), Worker,
                                              nodeId, startNode, stopNode)
import           Serokell.Util.Concurrent    (modifyTVarS)
import           System.Random               (mkStdGen)
import           Test.QuickCheck             (Property)
import           Test.QuickCheck.Arbitrary   (Arbitrary (..))
import           Test.QuickCheck.Modifiers   (getLarge)
import           Test.QuickCheck.Property    (Testable (..), failed, reason, succeeded)


-- * Parcel

data Parcel = Parcel
    { parcelNo  :: Int
    , toProcess :: Bool
    } deriving (Eq, Ord, Show, Generic)

instance Binary Parcel

instance Arbitrary Parcel where
    arbitrary = Parcel <$> (getLarge <$> arbitrary) <*> arbitrary


-- * TestState

data TestState = TestState
    { _fails         :: [String]
    , _expected      :: S.Set Parcel
    , _activeWorkers :: Int
    }

mkTestState :: TestState
mkTestState = TestState
    { _fails         = []
    , _expected      = S.empty
    , _activeWorkers = 0
    }

makeLenses ''TestState

instance Testable TestState where
    property TestState{..}
        | not $ null _fails      = property failed
            { reason = "Fails: \n" ++ L.intercalate "\n" (("\t" ++) <$> _fails) }

        | not $ S.null _expected = property failed
            { reason = "Missed messages: " ++ show _expected }

        | otherwise              = property succeeded

modifyTestState :: MonadIO m => TVar TestState -> StateT TestState STM () -> m ()
modifyTestState ts how = liftIO . atomically $ modifyTVarS ts how

addFail :: MonadIO m => TVar TestState -> String -> m ()
addFail testState desc = modifyTestState testState $ fails %= (desc :)

reportingFail :: TVar TestState -> String -> Production () -> Production ()
reportingFail testState actionName act = do
    act `catch` \(SomeException e) ->
        addFail testState $ "Error thrown in " ++ actionName ++ ": " ++ show e

newWork :: TVar TestState -> String -> Production () -> Production ()
newWork testState workerName act = do
    reportingFail testState workerName act
    modifyTestState testState $ activeWorkers -= 1


-- * Misc

-- I guess, errors in network-transport wasn't supposed to be processed in such way ^^
throwLeft :: Exception e => Production (Either e a) -> Production a
throwLeft = (>>= f)
  where
    f (Left e)  = throw e
    f (Right a) = return a

-- | Await for predicate to become True, with timeout
awaitSTM :: Int -> STM Bool -> Production ()
awaitSTM time predicate = do
    tvar <- liftIO $ newTVarIO False
    void . fork $ do
        delay time
        liftIO . atomically $ writeTVar tvar True
    liftIO . atomically $
        check =<< (||) <$> predicate <*> readTVar tvar


-- * Talk style

-- | Way to send pack of messages
data TalkStyle
    = SingleMessageStyle
    | ConversationStyle

instance Show TalkStyle where
    show SingleMessageStyle = "single-message style"
    show ConversationStyle  = "conversation style"

sendAll
    :: ( Binary header, Binary body, Monad m )
    => TalkStyle
    -> SendActions header m
    -> NodeId
    -> MessageName
    -> [(header, body)]
    -> m ()
sendAll SingleMessageStyle sendActions peerId msgName msgs =
    forM_ msgs $ uncurry $ sendTo sendActions peerId msgName

sendAll ConversationStyle  sendActions peerId msgName msgs =
    withConnectionTo sendActions @_ @Void peerId msgName $
        \cactions -> forM_ msgs $ uncurry $ send cactions

receiveAll
    :: ( Binary header, Binary body, Monad m )
    => TalkStyle
    -> (body -> m ())
    -> ListenerAction header m
receiveAll SingleMessageStyle handler =
    ListenerActionOneMsg $ \_ _ -> handler
receiveAll ConversationStyle  handler =
    ListenerActionConversation @_ @_ @Void $ \_ cactions ->
        let loop = do mmsg <- recv cactions
                      for_ mmsg $ \msg -> handler msg >> loop
        in  loop


-- * Test template

deliveryTest :: Binary header
             => TVar TestState
             -> [NodeId -> Worker header Production]
             -> [Listener header Production]
             -> Maybe (PreListener header Production)
             -> IO Property
deliveryTest testState workers listeners prelistener = runProduction $ do
    transport_ <- throwLeft $ liftIO $ TCP.createTransport "127.0.0.1" "10342" TCP.defaultTCPParameters
    let transport = concrete transport_
    endpoint1 <- throwLeft $ newEndPoint transport
    endpoint2 <- throwLeft $ newEndPoint transport

    let prng1 = mkStdGen 0
    let prng2 = mkStdGen 1

        -- launch nodes
    rec { cliNode  <- startNode endpoint1 prng1 (sequence workers servNodeId) Nothing []
        ; servNode <- startNode endpoint2 prng2 [] prelistener listeners
        ; let servNodeId = nodeId servNode
        }

    -- wait for all processes to stop
    liftIO . atomically $
        check . (== 0) . _activeWorkers =<< readTVar testState

    -- wait for receiver to get everything, but not for too long
    awaitSTM 1000000 $ S.null . _expected <$> readTVar testState

    -- stop nodes
    mapM_ stopNode [cliNode, servNode]
    closeTransport transport

    -- wait till port gets free
    delay 10000

    -- form test results
    liftIO . atomically $
        property <$> readTVar testState
