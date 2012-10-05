{-# LANGUAGE RecordWildCards #-}
module Server (serverMain) where

import Control.Concurrent
import Control.Monad
import Data.Maybe (fromMaybe)
import Graphics.Gloss.Data.Point
import Graphics.Gloss.Geometry.Line
import Network
import System.IO
import Data.Time.Clock

import Simulation
import NetworkMessages
import ListUtils

npcCount :: Int
npcCount = 10

serverMain :: Int -> IO ()
serverMain n = do
  sock <- listenOn gamePort
  _ <- forkIO $ do
    (hs, names) <- getConnections sock n
    sClose sock
    w   <- initServerWorld n names
    var <- newMVar w
    let setCommand = generateSetWorld w
    announce setCommand hs
    -- these handles are only to be used for reading
    rawHs <- unsafeReadHandles hs
    forM_ (zip [0..] rawHs) $ \(i,h) ->
       forkIO $ clientSocketLoop i hs h var
    runServer hs var
  _ <- getLine
  return ()

generateSetWorld :: ServerWorld -> ServerCommand
generateSetWorld w = SetWorld [(npcPos npc, npcFacing npc) | npc <- allNpcs w]

allNpcs :: ServerWorld -> [NPC]
allNpcs w = map playerNpc (serverPlayers w) ++ serverNpcs w

isStuckPlayer :: Player -> Bool
isStuckPlayer p =
  case npcState (playerNpc p) of
    Dead          -> True
    Attacking {}  -> True
    _             -> False

clientSocketLoop :: Int -> Handles -> Handle -> MVar ServerWorld -> IO ()
clientSocketLoop i hs h var = forever $
  do ClientCommand cmd <- hGetClientCommand h
     putStrLn $ "Client command: " ++ show cmd
     msgs <- modifyMVar var $ \w -> return $
       let players = serverPlayers w
           (me,them) = extract i players
           updatePlayerNpc f = w { serverPlayers = updateList i (mapPlayerNpc f) (serverPlayers w) }

       in case cmd of
            _        | not (serverActive w) || isStuckPlayer me -> (w,[])
            Move _ pos0 ->
              -- Disregard where the player says he is moving from
              let pos = constrainPoint (npcPos (playerNpc me)) pos0
              in if pointInBox pos boardMin boardMax
                 then   ( updatePlayerNpc $ \npc -> walkingNPC npc pos
                        , [ServerCommand i (Move (npcPos (playerNpc me)) pos)]
                        )
                 else   (w, [])
            Stop     -> ( updatePlayerNpc $ \npc -> waitingNPC npc Nothing False
                        , [ServerCommand i cmd]
                        )
            Attack   -> let (me', them', npcs', cmds) = performAttack me them (serverNpcs w)
                        in  (w { serverPlayers = insertPlayer me' them'
                               , serverNpcs    = npcs'
                               }
                            , cmds
                            )
            _        -> (w,[])
     forM_ msgs $ \msg -> announce msg hs

getConnections :: Socket -> Int -> IO (Handles,[String])
getConnections s n =
  do var <- newMVar []
     aux (Handles var) [] n
  where
  aux hs names 0 = return (hs, names)
  aux hs names i =
    do announce (ServerWaiting i) hs
       (h,host,port) <- accept s
       hSetBuffering h LineBuffering
       ClientJoin name <- hGetClientCommand h
       putStrLn $ "Got connection from " ++ name ++ "@" ++ host ++ ":" ++ show port
       addHandle h hs
       aux hs (name:names) (i-1)

runServer :: Handles -> MVar ServerWorld -> IO a
runServer hs w = forever $
  do 
     let period = recip $ fromIntegral eventsPerSecond
     before <- getCurrentTime
     modifyMVar_ w $ updateServerWorld hs period
     after  <- getCurrentTime
     let delayUs :: Float
         delayUs = 1000000 * realToFrac (diffUTCTime after before)
     threadDelay $ truncate $ 1000000 / fromIntegral eventsPerSecond - delayUs

initServerWorld :: Int -> [String] -> IO ServerWorld
initServerWorld playerCount names =
  do serverPlayers <- zipWithM initPlayer [0 ..] names
     serverNpcs    <- mapM (initServerNPC True) [playerCount .. npcCount + playerCount - 1]
     let serverActive = True
     return ServerWorld { .. }

updateServerWorld    :: Handles -> Float -> ServerWorld -> IO ServerWorld
updateServerWorld hs t w
  | not (serverActive w) = return w
  | otherwise =
     do pcs'  <- mapM (updatePlayer hs t) $ serverPlayers w
   
        let winners = filter isWinner pcs'
        unless (null winners) $
               announce (ServerMessage ("Winner! " ++ show (map playerUsername winners))) hs
        npcs' <- mapM (updateNPC hs t True) $ serverNpcs    w
        return w { serverPlayers = pcs'
                 , serverNpcs    = npcs'
                 , serverActive  = null winners
                 }

updatePlayer :: Handles -> Float -> Player -> IO Player
updatePlayer hs t p =
  do npc' <- updateNPC hs t False $ playerNpc p
     let p' = p { playerNpc = npc' }
     case whichPillar (npcPos npc') of
       Just i | i `notElem` playerVisited p -> 
         do announce ServerDing hs
            return p' { playerVisited = i : playerVisited p' }
       _ -> return p'

isWinner :: Player -> Bool
isWinner p = length (playerVisited p) == length pillars

updateNPC :: Handles -> Float -> Bool -> NPC -> IO NPC
updateNPC hs t think npc =
  do let (npc',mbTask) = updateNPC' t npc

     case guard think >> mbTask of

       Just ChooseWait ->
         do time <- pickWaitTime True
            return $ waitingNPC npc' time False

       Just ChooseDestination ->
         do tgt <- randomBoardPoint
            announce (ServerCommand (npcName npc') (Move (npcPos npc) tgt)) hs
            return $ walkingNPC npc' tgt

       Nothing -> return npc'

constrainPoint :: Point -> Point -> Point
constrainPoint from
  = aux intersectSegVertLine (fst boardMin)
  . aux intersectSegVertLine (fst boardMax)
  . aux intersectSegHorzLine (snd boardMin)
  . aux intersectSegHorzLine (snd boardMax)
  where
  aux f x p = fromMaybe p (f from p x)

newtype Handles = Handles (MVar [Handle])

addHandle :: Handle -> Handles -> IO ()
addHandle h (Handles var) = modifyMVar_ var $ \hs -> return (h:hs)

unsafeReadHandles :: Handles -> IO [Handle]
unsafeReadHandles (Handles var) = readMVar var

announce :: ServerCommand -> Handles -> IO ()
announce msg (Handles var) = withMVar var $ \hs -> mapM_ (`hPutServerCommand` msg) hs

