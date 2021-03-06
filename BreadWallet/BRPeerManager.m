//
//  BRPeerManager.m
//  BreadWallet
//
//  Created by Aaron Voisine on 10/6/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "BRPeerManager.h"
#import "BRPeer.h"
#import "BRPeerEntity.h"
#import "BRBloomFilter.h"
#import "BRKeySequence.h"
#import "BRTransaction.h"
#import "BRMerkleBlock.h"
#import "BRMerkleBlockEntity.h"
#import "BRWalletManager.h"
#import "BRWallet.h"
#import "NSString+Base58.h"
#import "NSData+Hash.h"
#import "NSManagedObject+Sugar.h"
#import <netdb.h>

#define FIXED_PEERS          @"FixedPeers"
#define MAX_CONNECTIONS      3
#define NODE_NETWORK         1  // services value indicating a node offers full blocks, not just headers
#define PROTOCOL_TIMEOUT     30.0
#define MAX_CONNECT_FAILURES 20 // notify user of network problems after this many connect failures in a row

#if BITCOIN_TESTNET

#define GENESIS_BLOCK_HASH @"000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943".hexToData.reverse

// The testnet genesis block uses the mainnet genesis block's merkle root. The hash is wrong using its own root.
#define GENESIS_BLOCK [[BRMerkleBlock alloc] initWithBlockHash:GENESIS_BLOCK_HASH version:1\
    prevBlock:@"0000000000000000000000000000000000000000000000000000000000000000".hexToData\
    merkleRoot:@"3ba3edfd7a7b12b27ac72c3e67768f617fC81bc3888a51323a9fb8aa4b1e5e4a".hexToData\
    timestamp:1296688602.0 - NSTimeIntervalSince1970 target:0x1d00ffffu nonce:414098458u totalTransactions:1\
    hashes:@"3ba3edfd7a7b12b27ac72c3e67768f617fC81bc3888a51323a9fb8aa4b1e5e4a".hexToData flags:@"00".hexToData height:0
    parentBlock:nil]

static const struct { uint32_t height; char *hash; time_t timestamp; uint32_t target; } checkpoint_array[] = {
    {  20160, "000000001cf5440e7c9ae69f655759b17a32aad141896defd55bb895b7cfc44e", 1345001466, 0x1c4d1756u },
    {  40320, "000000008011f56b8c92ff27fb502df5723171c5374673670ef0eee3696aee6d", 1355980158, 0x1d00ffffu },
    {  60480, "00000000130f90cda6a43048a58788c0a5c75fa3c32d38f788458eb8f6952cee", 1363746033, 0x1c1eca8au },
    {  80640, "00000000002d0a8b51a9c028918db3068f976e3373d586f08201a4449619731c", 1369042673, 0x1c011c48u },
    { 100800, "0000000000a33112f86f3f7b0aa590cb4949b84c2d9c673e9e303257b3be9000", 1376543922, 0x1c00d907u },
    { 120960, "00000000003367e56e7f08fdd13b85bbb31c5bace2f8ca2b0000904d84960d0c", 1382025703, 0x1c00df4cu },
    { 141120, "0000000007da2f551c3acd00e34cc389a4c6b6b3fad0e4e67907ad4c7ed6ab9f", 1384495076, 0x1c0ffff0u },
    { 161280, "0000000001d1b79a1aec5702aaa39bad593980dfe26799697085206ef9513486", 1388980370, 0x1c03fffcu },
    { 181440, "00000000002bb4563a0ec21dc4136b37dcd1b9d577a75a695c8dd0b861e1307e", 1392304311, 0x1b336ce6u },
    { 201600, "0000000000376bb71314321c45de3015fe958543afcbada242a3b1b072498e38", 1393813869, 0x1b602ac0u }
};

static const char *dns_seeds[] = {
    "localhost"
};

#else // main net

#define GENESIS_BLOCK_HASH @"192047379f33ffd2bbbab3d53b9c4b9e9b72e48f888eadb3dcf57de95a6038ad".hexToData.reverse

#define GENESIS_BLOCK [[BRMerkleBlock alloc] initWithBlockHash:GENESIS_BLOCK_HASH version:1\
    prevBlock:@"0000000000000000000000000000000000000000000000000000000000000000".hexToData\
    merkleRoot:@"7294da28c1b8eeba868388b14e2205874fb512f0ca31c2f583002557175f2c9c".hexToData\
    timestamp:1394002925.0 - NSTimeIntervalSince1970 target:0x1e0ffff0L nonce:386295993u totalTransactions:1\
    hashes:@"5b2a3f53f605d62c53e62932dac6925e3d74afa5a4b459745c36d42d0ed26a69".hexToData flags:@"00".hexToData height:0\
    parentBlock:nil]

// blockchain checkpoints, these are also used as starting points for partial chain downloads, so they need to be at
// difficulty transition boundaries in order to verify the block difficulty at the immediately following transition
// DEFCOIN:
static const struct { uint32_t height; char *hash; uint32_t timestamp; uint32_t target; } checkpoint_array[] = {
    {      0, "192047379f33ffd2bbbab3d53b9c4b9e9b72e48f888eadb3dcf57de95a6038ad", 1394002925, 0x1e0ffff0u },
    {  14400, "514e7963c509f2def8eb0835e17237972a2b166217c2b4280f2dec6815c8d2c9", 1395859174, 0x1e0b797au },
    {  28800, "503893d4d8d78e9f18f6c0379db39f950f15d122106978fdd83f0cc426ff4385", 1397162024, 0x1d01089fu },
    {  43200, "97c3e51590ecc9ec506115afaea4baa5dcd3b51d40b7462a105601d0476746bb", 1398890819, 0x1d00d355u },
    {  57600, "6cbc4e1a53d1bb26354a53892c993ea7f0b7a00727321843820f4d97eecdb27a", 1400657882, 0x1d00f49eu },
    {  72000, "f4030900554ff8d243291c9c472b7e83a9f812f1eba7d06fff545c0ee6c1897c", 1402492594, 0x1d01a4f7u },
    {  86400, "384f37d1d192388ce156c6979cbf872b6126b05509ae589ce9f3307b0f9be7b1", 1404299640, 0x1d01bda5u },
    { 100800, "b697bf16f3cb0ffed99f1c9e4f90c3836cab30facef7846e53b56a9fc2ead468", 1405963430, 0x1c411eecu },
    { 115200, "322a9f752af8b271d174d1891ea3577e3b13433d50d356e88c3c838d6c72020b", 1408405005, 0x1d009d6cu },
    { 129600, "4c576176529c552a2af598c4a6ebf82398d4c0dc86ed8870a36adf84f3ccb1cb", 1410217815, 0x1d008e9eu },
    { 144000, "785b52e8a82d93a16113c4ce2570c82f8d40c46a4ae30fea138cfe2d7abb7e9e", 1412043815, 0x1d016794u },
    { 158400, "3950c77eef45dca5be344ca6448009532630f136cf4f8d1b6e2d2073ec8c246c", 1414923535, 0x1d010713u },
    { 172800, "932b997b450021fc32eb0385f4f0ca605a4603cb9c3b165de3f5123ccc75fb8e", 1418224590, 0x1d00842eu },
    { 187200, "310e8b365d0d255b6b6cc8f89eb6f9248b8de7df5a3cb80f3e0349b4b41ecdc2", 1421720420, 0x1c0ff309u },
    { 201600, "53e3ec941246e387fd2922ef1e1a374512b18f04b40fe3b84f6da122c19b99f7", 1424149838, 0x1c54c507u },
    { 216000, "81cc36fbaa5ca78d4c78efa0113ea4c6023be8dece0fe15844b1986a69af75de", 1427287653, 0x1d009494u },
    { 230400, "00df53327329424645a49dd9f6ed88b8989a68e9dec9dabf9dfa009647d807a1", 1429107215, 0x1d01226cu },
    { 244800, "6b394aeb43ec33575515ed2b10d1003d535d3cd6288bfdaac52bfdc9cbecf3a0", 1431495431, 0x1d00b0f6u },
    { 259200, "ba9835ea8b76904009a746469813526a86b36d6819a3b9a06205e3ba31d0188e", 1433894573, 0x1c6991fcu },
    { 273600, "c1b8911fa0d9f9d10bff932479f76c52608de225e35d0e72c8a4c1a5c1953bcb", 1435666445, 0x1d008643u },
    { 288000, "7ea65baf6bbad9099cf3631f798975fadede45657580a7bf5b33cb53c9420de1", 1437525918, 0x1c61262bu },
    { 302400, "15d78044a7d41a4bdc4f91c61c9525a57333f2589470346afd4eb224f356e932", 1439440639, 0x1c48f0c8u },
    { 316800, "6c9939c6a0669c0a98ed25c7f7eb5ae556a0f3507908fc7f1f7dccca6edb9c94", 1441468915, 0x1c48627au },
    { 331200, "ad26fe9b496b514cfa6b4677789e45f2261c69d15190736b94ec07016255effb", 1443617172, 0x1c47cf7bu },
    { 345600, "765f83fb2dd010a91e0052945ce484a870b1955a3d23955c494c9ac24be188e6", 1446726152, 0x1d01ccb7u },
    { 360000, "2e7bbf22b40649d960ffc1a838643bb0f0b97c89c06365af77d40425b3801453", 1448473894, 0x1d0205a2u },
    { 374400, "2dac540d857d14baaeda2e258c20183c52aa3bba70fbfab151d63c33ff4c5523", 1450265201, 0x1d03accdu },
    { 388800, "d191a763721800b3dcb9230a339412aca8ede6c319de1dd471382d2281eb8ce0", 1452040394, 0x1d022951u },
    { 403200, "b6fe8822441ce4fb2ea23ccdc4d35f512e7521bb3a053fe33790a94cc7400ddd", 1453841117, 0x1d039da1u },
    { 417600, "6f8dcba121ccd354d3a92c1bf84a566669d187d27ae68af74012afcb4730efc2", 1455564603, 0x1d034becu },
    { 432000, "6a523098fc7b465ebff95f41c34a694692ef8888360201e7080d3dfe3ff3a30d", 1457305573, 0x1d033ebcu },
    { 446400, "a701afe3a2dbbb8ae5bfdcfa6e0b090b45e2691eba79ad47a95205e3ab35b368", 1459042349, 0x1d03774eu },
    { 460800, "a26f4709019171371f5dead6d4988fca6bcd05106fadc0c27bd3ec2715cbf555", 1460776514, 0x1d034125u },
    { 475200, "e91e1cb5c465338f64ae924125745111d188fa63ba7ea82d78da96541d8d5f19", 1462523130, 0x1d0385ebu },
    { 504000, "7b092f6862a62bfdcf3d234542d9af277b85958c4bd3a72873e23af0d354616e", 1466021413, 0x1d0561a4u },
    { 518400, "8b9bc518f88f54f1ca749371503251ab4771fc6d12cd977186daffb1aca43ccb", 1467744164, 0x1d04f50du },
    { 532800, "19a516baf53daa2fffc19aa665bb35a2e1edfe1e13375ee7299ced81eb49f0c7", 1469411919, 0x1d015f2bu }
};

static const char *dns_seeds[] = {
    "seed.beerwallet.org",
    "seed2.beerwallet.org"
};

#endif

@interface BRPeerManager ()

@property (nonatomic, strong) NSMutableOrderedSet *peers;
@property (nonatomic, strong) NSMutableSet *connectedPeers, *misbehavinPeers;
@property (nonatomic, strong) BRPeer *downloadPeer;
@property (nonatomic, assign) uint32_t tweak, syncStartHeight, filterUpdateHeight;
@property (nonatomic, strong) BRBloomFilter *bloomFilter;
@property (nonatomic, assign) double filterFpRate;
@property (nonatomic, assign) NSUInteger taskId, connectFailures;
@property (nonatomic, assign) NSTimeInterval earliestKeyTime, lastRelayTime;
@property (nonatomic, strong) NSMutableDictionary *blocks, *orphans, *checkpoints, *txRelays, *txRejections;
@property (nonatomic, strong) NSMutableDictionary *publishedTx, *publishedCallback;
@property (nonatomic, strong) BRMerkleBlock *lastBlock, *lastOrphan;
@property (nonatomic, strong) dispatch_queue_t q;
@property (nonatomic, strong) id resignActiveObserver, seedObserver;

@end

@implementation BRPeerManager

+ (instancetype)sharedInstance
{
    static id singleton = nil;
    static dispatch_once_t onceToken = 0;
    
    dispatch_once(&onceToken, ^{
        srand48(time(NULL)); // seed psudo random number generator (for non-cryptographic use only!)
        singleton = [self new];
    });
    
    return singleton;
}

- (instancetype)init
{
    if (! (self = [super init])) return nil;

    self.earliestKeyTime = [[BRWalletManager sharedInstance] seedCreationTime];
    self.connectedPeers = [NSMutableSet set];
    self.misbehavinPeers = [NSMutableSet set];
    self.tweak = (uint32_t)mrand48();
    self.taskId = UIBackgroundTaskInvalid;
    self.q = dispatch_queue_create("peermanager", NULL);
    self.orphans = [NSMutableDictionary dictionary];
    self.txRelays = [NSMutableDictionary dictionary];
    self.txRejections = [NSMutableDictionary dictionary];
    self.publishedTx = [NSMutableDictionary dictionary];
    self.publishedCallback = [NSMutableDictionary dictionary];

    for (BRTransaction *tx in [[[BRWalletManager sharedInstance] wallet] recentTransactions]) {
        if (tx.blockHeight != TX_UNCONFIRMED) break;
        self.publishedTx[tx.txHash] = tx; // add unconfirmed tx to mempool
    }

    self.resignActiveObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            [self savePeers];
            [self saveBlocks];
            [BRMerkleBlockEntity saveContext];
            if (self.syncProgress >= 1.0) [self.connectedPeers makeObjectsPerformSelector:@selector(disconnect)];
        }];

    self.seedObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRWalletManagerSeedChangedNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            self.earliestKeyTime = [[BRWalletManager sharedInstance] seedCreationTime];
            self.syncStartHeight = 0;
            [self.orphans removeAllObjects];
            [self.txRelays removeAllObjects];
            [self.txRejections removeAllObjects];
            [self.publishedTx removeAllObjects];
            [self.publishedCallback removeAllObjects];
            [BRMerkleBlockEntity deleteObjects:[BRMerkleBlockEntity allObjects]];
            [BRMerkleBlockEntity saveContext];
            _blocks = nil;
            _bloomFilter = nil;
            _lastBlock = nil;
            _lastOrphan = nil;
            [self.connectedPeers makeObjectsPerformSelector:@selector(disconnect)];
        }];

    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (self.resignActiveObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.resignActiveObserver];
    if (self.seedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.seedObserver];
}

- (NSMutableOrderedSet *)peers
{
    if (_peers.count >= MAX_CONNECTIONS) return _peers;

    @synchronized(self) {
        if (_peers.count >= MAX_CONNECTIONS) return _peers;
        _peers = [NSMutableOrderedSet orderedSet];

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

        [[BRPeerEntity context] performBlockAndWait:^{
            for (BRPeerEntity *e in [BRPeerEntity allObjects]) {
                if (e.misbehavin == 0) [_peers addObject:[e peer]];
                else [self.misbehavinPeers addObject:[e peer]];
            }
        }];

        if (_peers.count < MAX_CONNECTIONS) {
            for (int i = 0; i < sizeof(dns_seeds)/sizeof(*dns_seeds); i++) { // DNS peer discovery
                struct hostent *h = gethostbyname(dns_seeds[i]);

                for (int j = 0; h != NULL && h->h_addr_list[j] != NULL; j++) {
                    uint32_t addr = CFSwapInt32BigToHost(((struct in_addr *)h->h_addr_list[j])->s_addr);

                    // give dns peers a timestamp between 3 and 7 days ago
                    [_peers addObject:[[BRPeer alloc] initWithAddress:addr port:BITCOIN_STANDARD_PORT
                                       timestamp:now - 24*60*60*(3 + drand48()*4) services:NODE_NETWORK]];
                }
            }

#if BITCOIN_TESTNET
            [self sortPeers];
            return _peers;
#endif
            if (_peers.count < MAX_CONNECTIONS) {
                // if DNS peer discovery fails, fall back on a hard coded list of peers
                // hard coded list is taken from the satoshi client, values need to be byte swapped to be host native
                for (NSNumber *address in [NSArray arrayWithContentsOfFile:[[NSBundle mainBundle]
                                           pathForResource:FIXED_PEERS ofType:@"plist"]]) {
                    // give hard coded peers a timestamp between 7 and 14 days ago
                    [_peers addObject:[[BRPeer alloc] initWithAddress:CFSwapInt32(address.intValue)
                                       port:BITCOIN_STANDARD_PORT timestamp:now - 24*60*60*(7 + drand48()*7)
                                       services:NODE_NETWORK]];
                }
            }
        }

        [self sortPeers];
        return _peers;
    }
}

- (NSMutableDictionary *)blocks
{
    if (_blocks.count > 0) return _blocks;

    [[BRMerkleBlockEntity context] performBlockAndWait:^{
        if (_blocks.count > 0) return;
        _blocks = [NSMutableDictionary dictionary];
        self.checkpoints = [NSMutableDictionary dictionary];

        _blocks[GENESIS_BLOCK_HASH] = GENESIS_BLOCK;

        // add checkpoints to the block collection
        for (int i = 0; i < sizeof(checkpoint_array)/sizeof(*checkpoint_array); i++) {
            NSData *hash = [NSString stringWithUTF8String:checkpoint_array[i].hash].hexToData.reverse;

            _blocks[hash] = [[BRMerkleBlock alloc] initWithBlockHash:hash version:1 prevBlock:nil merkleRoot:nil
                             timestamp:checkpoint_array[i].timestamp - NSTimeIntervalSince1970
                             target:checkpoint_array[i].target nonce:0 totalTransactions:0 hashes:nil flags:nil
                             height:checkpoint_array[i].height parentBlock:nil];
            assert([_blocks[hash] isValid]);
            self.checkpoints[@(checkpoint_array[i].height)] = hash;
        }

        for (BRMerkleBlockEntity *e in [BRMerkleBlockEntity allObjects]) {
            _blocks[e.blockHash] = [e merkleBlock];
        };
    }];

    return _blocks;
}

// this is used as part of a getblocks or getheaders request
- (NSArray *)blockLocatorArray
{
    // append 10 most recent block hashes, decending, then continue appending, doubling the step back each time,
    // finishing with the genisis block (top, -1, -2, -3, -4, -5, -6, -7, -8, -9, -11, -15, -23, -39, -71, -135, ..., 0)
    NSMutableArray *locators = [NSMutableArray array];
    int32_t step = 1, start = 0;
    BRMerkleBlock *b = self.lastBlock;

    while (b && b.height > 0) {
        [locators addObject:b.blockHash];
        if (++start >= 10) step *= 2;

        for (int32_t i = 0; b && i < step; i++) {
            b = self.blocks[b.prevBlock];
        }
    }

    [locators addObject:GENESIS_BLOCK_HASH];

    return locators;
}

- (BRMerkleBlock *)lastBlock
{
    if (_lastBlock) return _lastBlock;

    NSFetchRequest *req = [BRMerkleBlockEntity fetchRequest];

    req.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"height" ascending:NO]];
    req.predicate = [NSPredicate predicateWithFormat:@"height >= 0 && height != %d", BLOCK_UNKOWN_HEIGHT];
    req.fetchLimit = 1;
    _lastBlock = [[BRMerkleBlockEntity fetchObjects:req].lastObject merkleBlock];

    // if we don't have any blocks yet, use the latest checkpoint that is at least a week older than earliestKeyTime
    for (int i = sizeof(checkpoint_array)/sizeof(*checkpoint_array) - 1; ! _lastBlock && i >= 0; i--) {
        if (checkpoint_array[i].timestamp + 7*24*60*60 - NSTimeIntervalSince1970 >= self.earliestKeyTime) continue;
        _lastBlock = [[BRMerkleBlock alloc]
                      initWithBlockHash:[NSString stringWithUTF8String:checkpoint_array[i].hash].hexToData.reverse
                      version:1 prevBlock:nil merkleRoot:nil
                      timestamp:checkpoint_array[i].timestamp - NSTimeIntervalSince1970
                      target:checkpoint_array[i].target nonce:0 totalTransactions:0 hashes:nil flags:nil
                      height:checkpoint_array[i].height parentBlock:nil];
    }

    if (! _lastBlock) _lastBlock = GENESIS_BLOCK;

    return _lastBlock;
}

- (uint32_t)lastBlockHeight
{
    return self.lastBlock.height;
}

- (uint32_t)estimatedBlockHeight
{
    return (self.downloadPeer.lastblock > self.lastBlockHeight) ? self.downloadPeer.lastblock : self.lastBlockHeight;
}

- (double)syncProgress
{
    if (! self.downloadPeer) return (self.syncStartHeight == self.lastBlockHeight) ? 0.05 : 0.0;
    if (self.lastBlockHeight >= self.downloadPeer.lastblock) return 1.0;
    return 0.1 + 0.9*(self.lastBlockHeight - self.syncStartHeight)/(self.downloadPeer.lastblock - self.syncStartHeight);
}

// number of connected peers
- (NSUInteger)peerCount
{
    NSUInteger count = 0;

    for (BRPeer *peer in self.connectedPeers) {
        if (peer.status == BRPeerStatusConnected) count++;
    }

    return count;
}

- (BRBloomFilter *)bloomFilter
{
    if (_bloomFilter) return _bloomFilter;

    self.filterUpdateHeight = self.lastBlockHeight;
    self.filterFpRate = BLOOM_DEFAULT_FALSEPOSITIVE_RATE;

    if (self.lastBlockHeight + BLOCK_DIFFICULTY_INTERVAL < self.downloadPeer.lastblock) {
        self.filterFpRate = BLOOM_REDUCED_FALSEPOSITIVE_RATE; // lower false positive rate during chain sync
    }
    else if (self.lastBlockHeight < self.downloadPeer.lastblock) { // partially lower fp rate if we're nearly synced
        self.filterFpRate -= (BLOOM_DEFAULT_FALSEPOSITIVE_RATE - BLOOM_REDUCED_FALSEPOSITIVE_RATE)*
                             (self.downloadPeer.lastblock - self.lastBlockHeight)/BLOCK_DIFFICULTY_INTERVAL;
    }

    BRWallet *w = [[BRWalletManager sharedInstance] wallet];
    NSUInteger elemCount = w.addresses.count + w.unspentOutputs.count;
    BRBloomFilter *filter = [[BRBloomFilter alloc] initWithFalsePositiveRate:self.filterFpRate
                             forElementCount:(elemCount < 200) ? elemCount*1.5 : elemCount + 100
                             tweak:self.tweak flags:BLOOM_UPDATE_ALL];

    for (NSString *address in w.addresses) { // add addresses to watch for any tx receiveing money to the wallet
        NSData *hash = address.addressToHash160;

        if (hash && ! [filter containsData:hash]) [filter insertData:hash];
    }

    for (NSData *utxo in w.unspentOutputs) { // add unspent outputs to watch for any tx sending money from the wallet
        if (! [filter containsData:utxo]) [filter insertData:utxo];
    }

    _bloomFilter = filter;
    return _bloomFilter;
}

- (void)connect
{
    if (! [[BRWalletManager sharedInstance] wallet]) return; // check to make sure the wallet has been created
    if (self.connectFailures >= MAX_CONNECT_FAILURES) self.connectFailures = 0; // this attempt is a manual retry
    
    if (self.syncProgress < 1.0) {
        if (self.syncStartHeight == 0) self.syncStartHeight = self.lastBlockHeight;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncStartedNotification object:nil];
        });
    }

    dispatch_async(self.q, ^{
        [self.connectedPeers minusSet:[self.connectedPeers objectsPassingTest:^BOOL(id obj, BOOL *stop) {
            return ([obj status] == BRPeerStatusDisconnected) ? YES : NO;
        }]];

        if (self.connectedPeers.count >= MAX_CONNECTIONS) return; // we're already connected to MAX_CONNECTIONS peers

        NSMutableOrderedSet *peers = [NSMutableOrderedSet orderedSetWithOrderedSet:self.peers];

        if (peers.count > 100) [peers removeObjectsInRange:NSMakeRange(100, peers.count - 100)];

        while (peers.count > 0 && self.connectedPeers.count < MAX_CONNECTIONS) {
            // pick a random peer biased towards peers with more recent timestamps
            BRPeer *p = peers[(NSUInteger)(pow(lrand48() % peers.count, 2)/peers.count)];

            if (p && ! [self.connectedPeers containsObject:p]) {
                [p setDelegate:self queue:self.q];
                p.earliestKeyTime = self.earliestKeyTime;
                [self.connectedPeers addObject:p];
                [p connect];
            }

            [peers removeObject:p];
        }

        if (self.connectedPeers.count == 0) {
            [self syncStopped];
            self.syncStartHeight = 0;

            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [NSError errorWithDomain:@"BeerWallet" code:1 userInfo:@{NSLocalizedDescriptionKey:
                                  NSLocalizedString(@"no peers found", nil)}];

                [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncFailedNotification
                 object:nil userInfo:@{@"error":error}];
            });
        }
    });
}

// rescans blocks and transactions after earliestKeyTime, a new random download peer is also selected due to the
// possibility that a malicious node might lie by omitting transactions that match the bloom filter
- (void)rescan
{
    if (! self.connected) return;

    _lastBlock = nil;

    // start the chain download from the most recent checkpoint that's at least a week older than earliestKeyTime
    for (int i = sizeof(checkpoint_array)/sizeof(*checkpoint_array) - 1; ! _lastBlock && i >= 0; i--) {
        if (checkpoint_array[i].timestamp + 7*24*60*60 - NSTimeIntervalSince1970 >= self.earliestKeyTime) continue;
        self.lastBlock = self.blocks[[NSString stringWithUTF8String:checkpoint_array[i].hash].hexToData.reverse];
    }

    if (! _lastBlock) _lastBlock = self.blocks[GENESIS_BLOCK_HASH];

    if (self.downloadPeer) { // disconnect the current download peer so a new random one will be selected
        [self.peers removeObject:self.downloadPeer];
        [self.downloadPeer disconnect];
    }

    self.syncStartHeight = self.lastBlockHeight;
    [self connect];
}

- (void)publishTransaction:(BRTransaction *)transaction completion:(void (^)(NSError *error))completion
{
    if (! [transaction isSigned]) {
        if (completion) {
            completion([NSError errorWithDomain:@"BeerWallet" code:401 userInfo:@{NSLocalizedDescriptionKey:
                        NSLocalizedString(@"dogecoin transaction not signed", nil)}]);
        }
        return;
    }

    if (! self.connected) {
        if (completion) {
            completion([NSError errorWithDomain:@"BeerWallet" code:-1009 userInfo:@{NSLocalizedDescriptionKey:
                        NSLocalizedString(@"not connected to the dogecoin network", nil)}]);
        }
        return;
    }

    self.publishedTx[transaction.txHash] = transaction;
    if (completion) self.publishedCallback[transaction.txHash] = completion;

    NSMutableSet *peers = [NSMutableSet setWithSet:self.connectedPeers];

    // instead of publishing to all peers, leave out the download peer to see if the tx propogates and gets relayed back
    // TODO: XXXX connect to a random peer with an empty or fake bloom filter just for publishing
    if (self.peerCount > 1) [peers removeObject:self.downloadPeer];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self performSelector:@selector(txTimeout:) withObject:transaction.txHash afterDelay:PROTOCOL_TIMEOUT];

        for (BRPeer *p in peers) {
            [p sendInvMessageWithTxHash:transaction.txHash];
        }
    });
}

// number of connected peers that have relayed the transaction
- (NSUInteger)relayCountForTransaction:(NSData *)txHash
{
    return [self.txRelays[txHash] count];
}

// seconds since reference date, 00:00:00 01/01/01 GMT
// NOTE: this is only accurate for the last two weeks worth of blocks, other timestamps are estimated from checkpoints
// BUG: this just doesn't work very well... we need to start storing tx metadata
- (NSTimeInterval)timestampForBlockHeight:(uint32_t)blockHeight
{
    if (blockHeight == TX_UNCONFIRMED) return [NSDate timeIntervalSinceReferenceDate] + 30; // average confirm time

    if (blockHeight > self.lastBlockHeight) { // future block, assume 1 minute per block after last block
        return self.lastBlock.timestamp + (blockHeight - self.lastBlockHeight)*1*60;
    }

    if (_blocks.count > 0) {
        if (blockHeight >= self.lastBlockHeight - BLOCK_DIFFICULTY_INTERVAL*2) { // recent block we have the header for
            BRMerkleBlock *block = self.lastBlock;

            while (block && block.height > blockHeight) {
                block = self.blocks[block.prevBlock];
            }

            if (block) return block.timestamp;
        }
    }
    else [[BRMerkleBlockEntity context] performBlock:^{ [self blocks]; }];

    uint32_t h = self.lastBlockHeight;
    NSTimeInterval t = self.lastBlock.timestamp + NSTimeIntervalSince1970;

    for (int i = sizeof(checkpoint_array)/sizeof(*checkpoint_array) - 1; i >= 0; i--) { // estimate from checkpoints
        if (checkpoint_array[i].height <= blockHeight) {
            t = checkpoint_array[i].timestamp + (t - checkpoint_array[i].timestamp)*
                (blockHeight - checkpoint_array[i].height)/(h - checkpoint_array[i].height);
            return t - NSTimeIntervalSince1970;
        }

        h = checkpoint_array[i].height;
        t = checkpoint_array[i].timestamp;
    }

    return GENESIS_BLOCK.timestamp + ((t - NSTimeIntervalSince1970) - GENESIS_BLOCK.timestamp)*blockHeight/h;
}

- (void)setBlockHeight:(int32_t)height forTxHashes:(NSArray *)txHashes
{
    [[[BRWalletManager sharedInstance] wallet] setBlockHeight:height forTxHashes:txHashes];
    
    if (height != TX_UNCONFIRMED) { // remove confirmed tx from publish list and relay counts
        [self.publishedTx removeObjectsForKeys:txHashes];
        [self.publishedCallback removeObjectsForKeys:txHashes];
        [self.txRejections removeObjectsForKeys:txHashes];
        [self.txRelays removeObjectsForKeys:txHashes];
    }
}

- (void)txTimeout:(NSData *)txHash
{
    void (^callback)(NSError *error) = self.publishedCallback[txHash];

    [self.publishedTx removeObjectForKey:txHash];
    [self.publishedCallback removeObjectForKey:txHash];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(txTimeout:) object:txHash];

    if (callback) {
        callback([NSError errorWithDomain:@"BeerWallet" code:BITCOIN_TIMEOUT_CODE userInfo:@{NSLocalizedDescriptionKey:
                  NSLocalizedString(@"transaction canceled, network timeout", nil)}]);
    }
}

- (void)syncTimeout
{
    //BUG: XXXX sync can stall if download peer continues to relay tx but not blocks
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - self.lastRelayTime < PROTOCOL_TIMEOUT) { // the download peer relayed something in time, so restart timer
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncTimeout) object:nil];
        [self performSelector:@selector(syncTimeout) withObject:nil
         afterDelay:PROTOCOL_TIMEOUT - (now - self.lastRelayTime)];
        return;
    }

    NSLog(@"%@:%d chain sync timed out", self.downloadPeer.host, self.downloadPeer.port);

    [self.peers removeObject:self.downloadPeer];
    [self.downloadPeer disconnect];
}

- (void)syncStopped
{
    if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground) {
        [self.connectedPeers makeObjectsPerformSelector:@selector(disconnect)];
        [self.connectedPeers removeAllObjects];
    }

    if (self.taskId != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
        self.taskId = UIBackgroundTaskInvalid;
        
        for (BRPeer *p in self.connectedPeers) { // after syncing, load filters and get mempools from the other peers
            if (p != self.downloadPeer) [p sendFilterloadMessage:self.bloomFilter.data];
            [p sendMempoolMessage];
            
            //BUG: XXXX sometimes a peer relays thousands of transactions after mempool msg, should detect and
            // disconnect if it's more than BLOOM_DEFAULT_FALSEPOSITIVE_RATE*10*<typical mempool size>*2
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncTimeout) object:nil];
    });
}

// unconfirmed transactions that aren't in the mempools of any of connected peers have likely dropped off the network
- (void)removeUnrelayedTransactions
{
    BRWalletManager *m = [BRWalletManager sharedInstance];

    for (BRTransaction *tx in m.wallet.recentTransactions) {
        if (tx.blockHeight != TX_UNCONFIRMED) break;
        if ([self.txRelays[tx.txHash] count] == 0) [m.wallet removeTransaction:tx.txHash];
    }
}

- (void)peerMisbehavin:(BRPeer *)peer
{
    peer.misbehavin++;
    [self.peers removeObject:peer];
    [self.misbehavinPeers addObject:peer];
    [peer disconnect];
    [self connect];
}

- (void)sortPeers
{
    [_peers sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        if ([obj1 timestamp] > [obj2 timestamp]) return NSOrderedAscending;
        if ([obj1 timestamp] < [obj2 timestamp]) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (void)savePeers
{
    NSMutableSet *peers = [[self.peers.set setByAddingObjectsFromSet:self.misbehavinPeers] mutableCopy];
    NSMutableSet *addrs = [NSMutableSet set];

    for (BRPeer *p in peers) {
        [addrs addObject:@((int32_t)p.address)];
    }

    [[BRPeerEntity context] performBlock:^{
        [BRPeerEntity deleteObjects:[BRPeerEntity objectsMatching:@"! (address in %@)", addrs]]; // remove deleted peers

        for (BRPeerEntity *e in [BRPeerEntity objectsMatching:@"address in %@", addrs]) { // update existing peers
            BRPeer *p = [peers member:[e peer]];

            if (p) {
                e.timestamp = p.timestamp;
                e.services = p.services;
                e.misbehavin = p.misbehavin;
                [peers removeObject:p];
            }
            else [e deleteObject];
        }

        for (BRPeer *p in peers) { // add new peers
            [[BRPeerEntity managedObject] setAttributesFromPeer:p];
        }
    }];
}

- (void)saveBlocks
{
    NSMutableSet *blockHashes = [NSMutableSet set];
    BRMerkleBlock *b = self.lastBlock;

    while (b) {
        [blockHashes addObject:b.blockHash];
        b = self.blocks[b.prevBlock];
    }

    [[BRMerkleBlockEntity context] performBlock:^{
        [BRMerkleBlockEntity deleteObjects:[BRMerkleBlockEntity objectsMatching:@"! (blockHash in %@)", blockHashes]];

        for (BRMerkleBlockEntity *e in [BRMerkleBlockEntity objectsMatching:@"blockHash in %@", blockHashes]) {
            [e setAttributesFromBlock:self.blocks[e.blockHash]];
            [blockHashes removeObject:e.blockHash];
        }

        for (NSData *hash in blockHashes) {
            [[BRMerkleBlockEntity managedObject] setAttributesFromBlock:self.blocks[hash]];
        }
    }];
}

#pragma mark - BRPeerDelegate

- (void)peerConnected:(BRPeer *)peer
{
    NSLog(@"%@:%d connected with lastblock %d", peer.host, peer.port, peer.lastblock);

    self.connectFailures = 0;
    peer.timestamp = [NSDate timeIntervalSinceReferenceDate]; // set last seen timestamp for peer

    if (peer.lastblock + 10 < self.lastBlock.height) { // drop peers that aren't synced yet, we can't help them
        [peer disconnect];
        return;
    }

    if (self.connected && (self.downloadPeer.lastblock >= peer.lastblock || self.lastBlock.height >= peer.lastblock)) {
        if (self.lastBlock.height < self.downloadPeer.lastblock) return; // don't load bloom filter yet if we're syncing
        [peer sendFilterloadMessage:self.bloomFilter.data];
        [peer sendMempoolMessage];
        return; // we're already connected to a download peer
    }

    // select the peer with the lowest ping time to download the chain from if we're behind
    // BUG: XXXX a malicious peer can report a higher lastblock to make us select them as the download peer, if two
    // peers agree on lastblock, use one of them instead
    for (BRPeer *p in self.connectedPeers) {
        if ((p.pingTime < peer.pingTime && p.lastblock >= peer.lastblock) || p.lastblock > peer.lastblock) peer = p;
    }

    [self.downloadPeer disconnect];
    self.downloadPeer = peer;
    _connected = YES;

    // every time a new wallet address is added, the bloom filter has to be rebuilt, and each address is only used for
    // one transaction, so here we generate some spare addresses to avoid rebuilding the filter each time a wallet
    // transaction is encountered during the blockchain download (generates twice the external gap limit for both
    // address chains)
    [[[BRWalletManager sharedInstance] wallet] addressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL*2 internal:NO];
    [[[BRWalletManager sharedInstance] wallet] addressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL*2 internal:YES];

    _bloomFilter = nil; // make sure the bloom filter is updated with any newly generated addresses
    [peer sendFilterloadMessage:self.bloomFilter.data];

    if (self.taskId == UIBackgroundTaskInvalid) { // start a background task for the chain sync
        self.taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{}];
    }
    
    if (self.lastBlock.height < peer.lastblock) { // start blockchain sync
        self.lastRelayTime = 0;

        dispatch_async(dispatch_get_main_queue(), ^{ // setup a timer to detect if the sync stalls
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncTimeout) object:nil];
            [self performSelector:@selector(syncTimeout) withObject:nil afterDelay:PROTOCOL_TIMEOUT];

            dispatch_async(self.q, ^{
                // request just block headers up to a week before earliestKeyTime, and then merkleblocks after that
                if (self.lastBlock.timestamp + 7*24*60*60 >= self.earliestKeyTime) {
                    [peer sendGetblocksMessageWithLocators:[self blockLocatorArray] andHashStop:nil];
                }
                else [peer sendGetheadersMessageWithLocators:[self blockLocatorArray] andHashStop:nil];
            });
        });
    }
    else { // we're already synced
        [self syncStopped];
        [peer sendGetaddrMessage]; // request a list of other bitcoin peers
        self.syncStartHeight = 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncFinishedNotification
             object:nil];
        });
    }
}

- (void)peer:(BRPeer *)peer disconnectedWithError:(NSError *)error
{
    NSLog(@"%@:%d disconnected%@%@", peer.host, peer.port, error ? @", " : @"", error ? error : @"");
    
    if ([error.domain isEqual:@"BeerWallet"] && error.code != BITCOIN_TIMEOUT_CODE) {
        [self peerMisbehavin:peer]; // if it's protocol error other than timeout, the peer isn't following the rules
    }
    else if (error) { // timeout or some non-protocol related network error
        [self.peers removeObject:peer];
        self.connectFailures++;
    }

    for (NSData *txHash in self.txRelays.allKeys) {
        [self.txRelays[txHash] removeObject:peer];
        [self.txRejections[txHash] removeObject:peer];
    }

    if ([self.downloadPeer isEqual:peer]) { // download peer disconnected
        _connected = NO;
        self.downloadPeer = nil;
        [self syncStopped];
        if (self.connectFailures > MAX_CONNECT_FAILURES) self.connectFailures = MAX_CONNECT_FAILURES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (! self.connected && self.connectFailures == MAX_CONNECT_FAILURES) {
            self.syncStartHeight = 0;
        
            // clear out stored peers so we get a fresh list from DNS on next connect attempt
            [self.connectedPeers removeAllObjects];
            [self.misbehavinPeers removeAllObjects];
            [BRPeerEntity deleteObjects:[BRPeerEntity allObjects]];
            _peers = nil;

            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncFailedNotification
             object:nil userInfo:error ? @{@"error":error} : nil];
        }
        else if (self.connectFailures < MAX_CONNECT_FAILURES) [self connect]; // try connecting to another peer
        
        [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
    });
}

- (void)peer:(BRPeer *)peer relayedPeers:(NSArray *)peers
{
    NSLog(@"%@:%d relayed %d peer(s)", peer.host, peer.port, (int)peers.count);
    if (peer == self.downloadPeer) self.lastRelayTime = [NSDate timeIntervalSinceReferenceDate];
    [self.peers addObjectsFromArray:peers];
    [self.peers minusSet:self.misbehavinPeers];
    [self sortPeers];

    // limit total to 2500 peers
    if (self.peers.count > 2500) [self.peers removeObjectsInRange:NSMakeRange(2500, self.peers.count - 2500)];

    NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate] - 3*60*60;

    // remove peers more than 3 hours old, or until there are only 1000 left
    while (self.peers.count > 1000 && [self.peers.lastObject timestamp] < t) {
        [self.peers removeObject:self.peers.lastObject];
    }

    if (peers.count > 1 && peers.count < 1000) { // peer relaying is complete when we receive fewer than 1000
        // this is a good time to remove unconfirmed tx that dropped off the network
        if (self.peerCount == MAX_CONNECTIONS && self.lastBlockHeight >= self.downloadPeer.lastblock) {
            [self removeUnrelayedTransactions];
        }

        [self savePeers];
        [BRPeerEntity saveContext];
    }
}

- (void)peer:(BRPeer *)peer relayedTransaction:(BRTransaction *)transaction
{
    BRWallet *w = [[BRWalletManager sharedInstance] wallet];

    NSLog(@"%@:%d relayed transaction %@", peer.host, peer.port, transaction.txHash);
    if (peer == self.downloadPeer) self.lastRelayTime = [NSDate timeIntervalSinceReferenceDate];

    if ([w registerTransaction:transaction]) {
        self.publishedTx[transaction.txHash] = transaction;

        // keep track of how many peers relay a tx, this indicates how likely it is to be confirmed in future blocks
        if (! self.txRelays[transaction.txHash]) self.txRelays[transaction.txHash] = [NSMutableSet set];

        if (! [self.txRelays[transaction.txHash] containsObject:peer]) {
            [self.txRelays[transaction.txHash] addObject:peer];
        
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification
                 object:nil];
            });
        }

        // the transaction likely consumed one or more wallet addresses, so check that at least the next <gap limit>
        // unused addresses are still matched by the bloom filter
        NSArray *external = [w addressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL internal:NO],
                *internal = [w addressesWithGapLimit:SEQUENCE_GAP_LIMIT_INTERNAL internal:YES];

        for (NSString *address in [external arrayByAddingObjectsFromArray:internal]) {
            NSData *hash = address.addressToHash160;

            if (! hash || [self.bloomFilter containsData:hash]) continue;

            // generate additional addresses so we don't have to update the filter after each new transaction
            [w addressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL*2 internal:NO];
            [w addressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL*2 internal:YES];

            _bloomFilter = nil; // reset the filter so a new one will be created with the new wallet addresses

            if (self.lastBlockHeight >= self.downloadPeer.lastblock) { // if we're syncing, only update download peer
                for (BRPeer *p in self.connectedPeers) {
                    [p sendFilterloadMessage:self.bloomFilter.data];
                }
            }
            else [self.downloadPeer sendFilterloadMessage:self.bloomFilter.data];

            // after adding addresses to the filter, re-request upcoming blocks that were requested using the old filter
            [self.downloadPeer rereqeustBlocksFrom:self.lastBlock.blockHash];
            break;
        }
    }
}

- (void)peer:(BRPeer *)peer rejectedTransaction:(NSData *)txHash withCode:(uint8_t)code
{
    if ([self.txRelays[txHash] containsObject:peer]) {
        [self.txRelays[txHash] removeObject:peer];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
        });
    }

    // keep track of possible double spend rejections and notify the user to do a rescan
    // NOTE: lots of checks here to make sure a malicious node can't annoy the user with rescan alerts
    if (code == 0x10 && self.publishedTx[txHash] != nil && ! [self.txRejections[txHash] containsObject:peer] &&
        [self.connectedPeers containsObject:peer]) {
        if (! self.txRejections[txHash]) self.txRejections[txHash] = [NSMutableSet set];
        [self.txRejections[txHash] addObject:peer];

        if ([self.txRejections[txHash] count] > 1 || self.peerCount < 3) {
            [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"transaction rejected", nil)
              message:NSLocalizedString(@"Your wallet may be out of sync.\n"
                                        "This can often be fixed by rescaning the blockchain.", nil) delegate:self
              cancelButtonTitle:NSLocalizedString(@"cancel", nil)
              otherButtonTitles:NSLocalizedString(@"rescan", nil), nil] show];
        }
    }
}

- (void)peer:(BRPeer *)peer relayedBlock:(BRMerkleBlock *)block
{
    if (peer == self.downloadPeer) self.lastRelayTime = [NSDate timeIntervalSinceReferenceDate];

    // ignore block headers that are newer than one week before earliestKeyTime (headers have 0 totalTransactions)
    if (block.totalTransactions == 0 && block.timestamp + 7*24*60*60 > self.earliestKeyTime) return;

    // track the observed bloom filter false positive rate using a low pass filter to smooth out variance
    if (peer == self.downloadPeer && block.totalTransactions > 0) {
        // 1% low pass filter, also weights each block by total transactions, using 400 tx per block as typical
        self.filterFpRate = self.filterFpRate*(1.0 - 0.01*block.totalTransactions/400) + 0.01*block.txHashes.count/400;

        if (self.filterFpRate > BLOOM_DEFAULT_FALSEPOSITIVE_RATE*10.0) { // false positive rate sanity check
            NSLog(@"%@:%d bloom filter false positive rate too high after %d blocks, disconnecting...", peer.host,
                  peer.port, self.lastBlockHeight - self.filterUpdateHeight);
            [self.downloadPeer disconnect];
        }
    }

    BRMerkleBlock *prev = self.blocks[block.prevBlock];
    NSTimeInterval transitionTime = 0;

    if (! prev) { // block is an orphan
        NSLog(@"%@:%d relayed orphan block %@, previous %@, last block is %@, height %d", peer.host, peer.port,
              block.blockHash, block.prevBlock, self.lastBlock.blockHash, self.lastBlock.height);

        // ignore orphans older than one week ago
        if (block.timestamp < [NSDate timeIntervalSinceReferenceDate] - 7*24*60*60) return;

        // call getblocks, unless we already did with the previous block, or we're still downloading the chain
        if (self.lastBlock.height >= peer.lastblock && ! [self.lastOrphan.blockHash isEqual:block.prevBlock]) {
            NSLog(@"%@:%d calling getblocks", peer.host, peer.port);
            [peer sendGetblocksMessageWithLocators:[self blockLocatorArray] andHashStop:nil];
        }

        self.orphans[block.prevBlock] = block; // orphans are indexed by previous block rather than their own hash
        self.lastOrphan = block;
        return;
    }

    block.height = prev.height + 1;

    if ((block.height % BLOCK_DIFFICULTY_INTERVAL) == 0) { // hit a difficulty transition, find previous transition time
        BRMerkleBlock *b = block;

        for (uint32_t i = 0; b && i < BLOCK_DIFFICULTY_INTERVAL; i++) {
            b = self.blocks[b.prevBlock];
        }

        transitionTime = b.timestamp;

        while (b) { // free up some memory
            b = self.blocks[b.prevBlock];
            if (b) [self.blocks removeObjectForKey:b.blockHash];
        }
    }

    // verify block difficulty
    if (! [block verifyDifficultyFromPreviousBlock:prev andTransitionTime:transitionTime andStoredBlocks:self.blocks]) {
        NSLog(@"%@:%d relayed block with invalid difficulty target %x, blockHash: %@", peer.host, peer.port,
              block.target, block.blockHash);
        [self peerMisbehavin:peer];
        return;
    }

    // verify block chain checkpoints
    if (self.checkpoints[@(block.height)] && ! [block.blockHash isEqual:self.checkpoints[@(block.height)]]) {
        NSLog(@"%@:%d relayed a block that differs from the checkpoint at height %d, blockHash: %@, expected: %@",
              peer.host, peer.port, block.height, block.blockHash, self.checkpoints[@(block.height)]);
        [self peerMisbehavin:peer];
        return;
    }

    if ([block.prevBlock isEqual:self.lastBlock.blockHash]) { // new block extends main chain
        if ((block.height % 500) == 0 || block.txHashes.count > 0 || block.height > peer.lastblock) {
            NSLog(@"adding block at height: %d, false positive rate: %f", block.height, self.filterFpRate);
        }

        self.blocks[block.blockHash] = block;
        self.lastBlock = block;
        [self setBlockHeight:block.height forTxHashes:block.txHashes];
    }
    else if (self.blocks[block.blockHash] != nil) { // we already have the block (or at least the header)
        if ((block.height % 500) == 0 || block.txHashes.count > 0 || block.height > peer.lastblock) {
            NSLog(@"%@:%d relayed existing block at height %d", peer.host, peer.port, block.height);
        }

        self.blocks[block.blockHash] = block;

        BRMerkleBlock *b = self.lastBlock;

        while (b && b.height > block.height) { // check if block is in main chain
            b = self.blocks[b.prevBlock];
        }

        if ([b.blockHash isEqual:block.blockHash]) { // if it's not on a fork, set block heights for its transactions
            [self setBlockHeight:block.height forTxHashes:block.txHashes];
            if (block.height == self.lastBlock.height) self.lastBlock = block;
        }
    }
    else { // new block is on a fork
        if (block.height <= BITCOIN_REFERENCE_BLOCK_HEIGHT) { // fork is older than the most recent checkpoint
            NSLog(@"ignoring block on fork older than most recent checkpoint, fork height: %d, blockHash: %@",
                  block.height, block.blockHash);
            return;
        }

        // special case, if a new block is mined while we're rescaning the chain, mark as orphan til we're caught up
        if (self.lastBlock.height < peer.lastblock && block.height > self.lastBlock.height + 1) {
            NSLog(@"marking new block at height %d as orphan until rescan completes", block.height);
            self.orphans[block.prevBlock] = block;
            self.lastOrphan = block;
            return;
        }

        NSLog(@"chain fork to height %d", block.height);
        self.blocks[block.blockHash] = block;
        if (block.height <= self.lastBlock.height) return; // if fork is shorter than main chain, ingore it for now

        NSMutableArray *txHashes = [NSMutableArray array];
        BRMerkleBlock *b = block, *b2 = self.lastBlock;

        while (b && b2 && ! [b.blockHash isEqual:b2.blockHash]) { // walk back to where the fork joins the main chain
            b = self.blocks[b.prevBlock];
            if (b.height < b2.height) b2 = self.blocks[b2.prevBlock];
        }

        NSLog(@"reorganizing chain from height %d, new height is %d", b.height, block.height);

        // mark transactions after the join point as unconfirmed
        for (BRTransaction *tx in [[[BRWalletManager sharedInstance] wallet] recentTransactions]) {
            if (tx.blockHeight <= b.height) break;
            [txHashes addObject:tx.txHash];
        }

        [self setBlockHeight:TX_UNCONFIRMED forTxHashes:txHashes];
        b = block;

        while (b.height > b2.height) { // set transaction heights for new main chain
            [self setBlockHeight:b.height forTxHashes:b.txHashes];
            b = self.blocks[b.prevBlock];
        }

        self.lastBlock = block;
    }

    if (block.height == peer.lastblock && block == self.lastBlock) { // chain download is complete
        [self saveBlocks];
        [BRMerkleBlockEntity saveContext];
        [self syncStopped];
        [peer sendGetaddrMessage]; // request a list of other bitcoin peers
        self.syncStartHeight = 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncFinishedNotification
             object:nil];
        });
    }

    if (block == self.lastBlock && self.orphans[block.blockHash]) { // check if the next block was received as an orphan
        BRMerkleBlock *b = self.orphans[block.blockHash];

        [self.orphans removeObjectForKey:block.blockHash];
        [self peer:peer relayedBlock:b];
    }

    if (block.height > peer.lastblock) { // notify that transaction confirmations may have changed
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
        });
    }
}

- (BRTransaction *)peer:(BRPeer *)peer requestedTransaction:(NSData *)txHash
{
    BRTransaction *tx = self.publishedTx[txHash];
    void (^callback)(NSError *error) = self.publishedCallback[txHash];
    
    if (tx) {
        [[[BRWalletManager sharedInstance] wallet] registerTransaction:tx];

        if (! self.txRelays[txHash]) self.txRelays[txHash] = [NSMutableSet set];
        [self.txRelays[txHash] addObject:peer];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
        });

        [self.publishedCallback removeObjectForKey:txHash];

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(txTimeout:) object:txHash];
            if (callback) callback(nil);
        });
    }

    return tx;
}

- (NSData *)peerBloomFilter:(BRPeer *)peer
{
    self.filterFpRate = self.bloomFilter.falsePositiveRate;
    self.filterUpdateHeight = self.lastBlockHeight;
    return self.bloomFilter.data;
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) return;
    [self rescan];
}

@end
