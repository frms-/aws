-- ------------------------------------------------------ --
-- Copyright © 2012 AlephCloud Systems, Inc.
-- ------------------------------------------------------ --

{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

module Route53.Samples where

import Data.Text              (Text)
import Data.List              (find)
import Data.Maybe             (fromJust)
import Data.Attempt           (Attempt(..), fromAttempt)
import Data.Semigroup         (Semigroup, (<>))
import Data.Monoid            (Monoid, mempty, mappend)

import Control.Monad (guard)
import Control.Applicative    ((<$>))
import Control.Monad.IO.Class (MonadIO)

import Network.HTTP.Conduit   (Manager, withManager)

import Aws                    (aws, Response(..), Transaction, DefaultServiceConfiguration, 
                               ServiceConfiguration, defaultConfiguration, baseConfiguration,
                               ResponseMetadata)
import Aws.Route53

-- -------------------------------------------------------------------------- --
-- Request Utils

instance (Monoid m, Semigroup a) => Semigroup (Response m a) where
     (Response m0 (Success a0)) <> (Response m1 (Success a1)) = Response (m0 `mappend` m1) (Success (a0 <> a1))
     (Response m0 (Success _))  <> (Response m1 (Failure e))  = Response (m0 `mappend` m1) (Failure e)
     (Response m0 (Failure e))  <> (Response m1 _)            = Response (m0 `mappend` m1) (Failure e)

-- | extract result of an 'Attempt' from a 'Response'
--
getResult :: Response m a -> Attempt a
getResult (Response _ a) = a

-- | A class for transactions with batched responses. Allows to
--   iterate and concatenate all responses.
--
--   Minimal complete implementation: 'nextRequest'.
--
class (Transaction r a, Semigroup a) => Batched r a  where
    nextRequest :: r -> (Response (ResponseMetadata a) a) -> Maybe r

requestAll :: (Batched r a, MonadIO m, Functor m) 
           => (r -> m (Response (ResponseMetadata a) a)) 
           -> r 
           -> m (Response (ResponseMetadata a) a) 
requestAll mkRequest request = do
    response <- mkRequest request
    case nextRequest request response of
        Nothing -> return response
        Just r -> (response <>) <$> requestAll mkRequest r

-- | Make a request using with the base configuration and the default
--   service configuration
--
makeDefaultRequest :: ( Transaction r a
                      , Functor m
                      , MonadIO m
                      , DefaultServiceConfiguration (ServiceConfiguration r)
                      ) 
                   => Manager -> r -> m (Response (ResponseMetadata a) a)
makeDefaultRequest manager request = do
    cfg <- baseConfiguration
    let scfg = defaultConfiguration
    aws cfg scfg manager request

-- | Executes the given request using the default configuration and a fresh 
--   connection manager. Extracts the enclosed response body and returns it 
--   within the IO monad.
--
--   The result is wrapped in an 'Attempt'.
--
makeSingleRequest :: (Transaction r a
                     , Show r
                     , DefaultServiceConfiguration (ServiceConfiguration r)
                     ) 
                  => r -> IO a
makeSingleRequest r = do
    fromAttempt =<< getResult <$> (withManager (\m -> makeDefaultRequest m r))

-- | Iterates request with batched responses until all batched are received 
--   using the default configuration and a fresh connection manager. The 
--   enclosed response bodies are extracted, concatenated (using 'mappend'
--   from 'Data.Monoid'), and returned within the IO monad.
--
--   The result is wrapped in an 'Attempt'.
--
makeSingleRequestAll :: (Transaction r a
                        , Batched r a
                        , Show r
                        , DefaultServiceConfiguration (ServiceConfiguration r)
                        ) 
                     => r -> IO a
makeSingleRequestAll r = 
    fromAttempt =<< getResult <$> withManager (\m -> requestAll (makeDefaultRequest m) r)

-- | Given a Changeid returns the change info status for the corresponding 
--   request.
--
getChangeStatus :: ChangeId -> IO ChangeInfoStatus
getChangeStatus changeId = 
    ciStatus . gcrChangeInfo <$> (makeSingleRequest $ getChange changeId)

-- | Extracts the ChangeId from a response using the given function to extract
--   the ChangeInfo from the response.
--
getChangeId :: Functor f => (a -> ChangeInfo) -> f a -> f ChangeId
getChangeId changeInfoExtractor response = ciId . changeInfoExtractor <$> response

-- | Example usage of getChangeId.
--
getChangeResourceRecordSetsResponseChangeId :: Functor f => f ChangeResourceRecordSetsResponse -> f ChangeId
getChangeResourceRecordSetsResponseChangeId response = getChangeId crrsrChangeInfo response

-- TODO implement wait for INSYNC

-- -------------------------------------------------------------------------- --
-- Hosted Zones

instance Semigroup ListHostedZonesResponse where
    a <> b = ListHostedZonesResponse 
           { lhzrHostedZones = lhzrHostedZones a <> lhzrHostedZones b
           , lhzrNextToken = lhzrNextToken b
           }


instance Batched ListHostedZones ListHostedZonesResponse where
    nextRequest _ (Response _ (Failure _)) = Nothing
    nextRequest _ (Response _ (Success ListHostedZonesResponse{..})) = 
        ListHostedZones Nothing . Just <$> lhzrNextToken

-- | Get all hosted zones of the user.
--
getAllZones :: IO HostedZones
getAllZones = lhzrHostedZones <$> makeSingleRequestAll listHostedZones

-- | Get a hosted zone by its 'HostedZoneId'.
--
getZoneById :: HostedZoneId -> IO HostedZone
getZoneById hzid = ghzrHostedZone <$> makeSingleRequest (getHostedZone hzid)

-- | Get a hosted zone by its domain name.
--   
--   Results in an error if no hosted zone exists for the given domain name.
--
getZoneByName :: Domain -> IO HostedZone
getZoneByName z = fromJust . find ((z==) . hzName) <$> getAllZones

-- | Returns the hosted zone id of the hosted zone for the given domain.
--
getZoneIdByName :: Domain -> IO HostedZoneId
getZoneIdByName hzName = hzId <$> getZoneByName hzName

-- -------------------------------------------------------------------------- --
-- Resource Records Sets

-- | Simplified construction for a ResourceRecordSet.
--
simpleResourceRecordSet :: Domain -> RecordType -> Int -> Text -> ResourceRecordSet
simpleResourceRecordSet domain rtype ttl value = 
    ResourceRecordSet domain rtype Nothing Nothing Nothing Nothing (Just ttl) [(ResourceRecord value)]

instance Semigroup ListResourceRecordSetsResponse where
    a <> b = ListResourceRecordSetsResponse
           { lrrsrResourceRecordSets = lrrsrResourceRecordSets a ++ lrrsrResourceRecordSets b
           , lrrsrIsTruncated = lrrsrIsTruncated b
           , lrrsrNextRecordName = lrrsrNextRecordName b
           , lrrsrNextRecordType = lrrsrNextRecordType b
           , lrrsrNextRecordIdentifier = lrrsrNextRecordIdentifier b
           , lrrsrMaxItems = lrrsrMaxItems b
           }

instance Batched ListResourceRecordSets ListResourceRecordSetsResponse where
    nextRequest _ (Response _ (Failure _)) = Nothing 
    nextRequest ListResourceRecordSets{..} (Response _ (Success ListResourceRecordSetsResponse{..})) = do
        guard (lrrsrIsTruncated)
        return $ ListResourceRecordSets lrrsHostedZoneId 
                                        lrrsrNextRecordName 
                                        lrrsrNextRecordType 
                                        lrrsrNextRecordIdentifier 
                                        lrrsrMaxItems

-- | Returns the resource record sets in the hosted zone with the given domain
--   name.
--
--   Note the 'zName' is the domain name of the hosted zone itself.
--
getResourceRecordSetsByHostedZoneName :: Domain -> IO ResourceRecordSets
getResourceRecordSetsByHostedZoneName zName = do
    hzid <- getZoneIdByName zName
    lrrsrResourceRecordSets <$> makeSingleRequestAll (listResourceRecordSets hzid)

-- | Lists all resource record sets in the hosted zone with the given hosted 
--   zone id.
--
getResourceRecordSets :: HostedZoneId -> IO ResourceRecordSets
getResourceRecordSets hzid = 
    lrrsrResourceRecordSets <$> makeSingleRequestAll (listResourceRecordSets hzid)

-- | Lists all resource record sets in the given hosted zone for the given 
--   domain.
--
getResourceRecordSetsByDomain :: HostedZoneId -> Domain -> IO ResourceRecordSets
getResourceRecordSetsByDomain hzid domain = do
    let req = (listResourceRecordSets hzid) { lrrsName = Just domain }
    lrrsrResourceRecordSets <$> makeSingleRequestAll req

-- | Returns all resource records sets in the hosted zone with the given hosted
--   zone id for the given DNS record type.
--
getResourceRecordSetsByType :: HostedZoneId -> RecordType -> IO ResourceRecordSets
getResourceRecordSetsByType hzid dnsRecordType = 
    filter ((== dnsRecordType) . rrsType) <$> getResourceRecordSets hzid

-- | Returns the resource record set of the given type for the given domain in 
--   the given hosted zone.
--
getResourceRecords :: HostedZoneId -> Domain -> RecordType -> IO ResourceRecordSet
getResourceRecords cid domain rtype = do
    let req = ListResourceRecordSets cid (Just domain) (Just rtype) Nothing (Just 1)
    head . lrrsrResourceRecordSets <$> (makeSingleRequest $ req)

-- | Updates the resouce records of the given type for the given domain in the 
--   given hosted zone using the given mapping function.
--
--   Recall that the functions in this module are example usages of the 
--   Aws.Route53 module. In a production environment one would reuse the same 
--   connection manager and configuration for all involved requests.
--
updateRecords :: HostedZoneId 
              -> Domain 
              -> RecordType 
              -> ([ResourceRecord] 
              -> [ResourceRecord]) 
              -> IO (ChangeResourceRecordSetsResponse, ChangeResourceRecordSetsResponse)
updateRecords cid domain rtype f = do
  -- Fixme fail more gracefully
  rrs <- getResourceRecords cid domain rtype
  let rrs' = rrs { rrsRecords = f (rrsRecords rrs) }
  -- Handle errors gracefully. What if we fail in the middle?
  r1 <- makeSingleRequest $ ChangeResourceRecordSets cid Nothing [(DELETE, rrs)]
  r2 <- makeSingleRequest $ ChangeResourceRecordSets cid Nothing [(CREATE, rrs')]
  return (r1, r2)

-- | Updates the A record for the given domain in the given zone to the given 
--   IP address (encoded as Text).
--
updateARecord :: HostedZoneId 
              -> Domain 
              -> Text 
              -> IO (ChangeResourceRecordSetsResponse, ChangeResourceRecordSetsResponse)
updateARecord cid domain newIP = updateRecords cid domain A (const [ResourceRecord newIP])


