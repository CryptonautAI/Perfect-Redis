//
//  CryptonautTests.swift
//  PerfectRedisTests
//
//  Created by Dimitar Ostoich on 18.11.17.
//

import XCTest
@testable import PerfectRedis
import Dispatch

class CryptonautTests: XCTestCase {
    var client : CryptonautRedisClient!
    override func setUp() {
        super.setUp()
        
        let clientId = RedisClientIdentifier(withHost: "d.getuptick.com", port: 11711)
        do {
        client = try CryptonautRedisClient(withClientIdentifier: clientId)
        }
        catch {
            XCTFail("Could not create client: \(error)")
        }
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testFetchTriggersAndUsers() {
        let expU = self.expectation(description: "Fetch users")
        let expT = self.expectation(description: "Fetch Triggers")
        
        fetchWithPattern(CryptonautRedisClient.Data(key:"u:*", value:CryptonautRedisClient.DataValue.hash([:]))) {
            print("Got users:\n\($0)")
            expU.fulfill()
        }
        
        fetchWithPattern(CryptonautRedisClient.Data(key:"t:*", value:CryptonautRedisClient.DataValue.hash([:]))) {
            print("Got triggers:\n\($0)")
            expT.fulfill()
        }
        
        wait(for: [expU, expT], timeout: 60)
    }
    
    func testFetchTriggers() {
        
        let exp = self.expectation(description: "Fetch Triggers")
        
        let requestKey = "t:*"
        let params = CryptonautRedisClient.Data(key:requestKey, value:CryptonautRedisClient.DataValue.hash([:]))
        fetchWithPattern(params) {
            print("Got triggers:\n\($0)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
    }

    func testFetchUsers() {
        
        let exp = self.expectation(description: "Fetch users")
        
        let requestKey = "u:*"
        let params = CryptonautRedisClient.Data(key:requestKey, value:CryptonautRedisClient.DataValue.hash([:]))
        fetchWithPattern(params) {
            print("Got users:\n\($0)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
    }
}

extension CryptonautTests {
    func fetchWithPattern(_ pattern:CryptonautRedisClient.Data, completion:@escaping (CryptonautRedisClient.GetResult<CryptonautRedisClient.Data>)->Void) {
        
        client.getData(forParams:pattern) { result in
            
            switch result {
            case .error(let error):
                XCTFail("Fetch failed: \(error)")
            case .value(let value):
                value.forEach { data in
                    switch (pattern.value, data.value) {
                    case (.list(let expected), .hash(let got)):
                        XCTFail("Expected response list {\(expected)} but received a hash {\(got)} with key {\(data.key)}")
                    case (.hash(let expected), .list(let got)):
                        XCTFail("Expected response hash {\(expected)} but received a list {\(got)} with key {\(data.key)}")
                    default:
                        break
                    }
                    
                }
            }
            
            completion(result)
        }
    }
}

public class CryptonautRedisClient {
    
    fileprivate var clientId : RedisClientIdentifier
    fileprivate var client : RedisClient!
    fileprivate let queue = DispatchQueue(label: "CryptonautRedisClient queue")
    
    public init(withClientIdentifier clientId:RedisClientIdentifier, databaseIndex:Int = 0) throws {
        self .clientId = clientId
        let group = DispatchGroup()
        group.enter()
        
        var error : Swift.Error?
        RedisClient.getClient(withIdentifier: self.clientId) { c in
            defer { group.leave() }
            do {
                self.client = try c()
            }
            catch let e {
                error = e
            }
        }
        group.wait()
        group.enter()
        
        self.client.select(index: databaseIndex) { response in
            defer { group.leave() }
            if response.isSimpleOK == false {
                error = Error.couldNotSelectDatabase(response.toString())
            }
        }
        group.wait()
        
        if let err = error { throw err }
    }
    
    deinit { RedisClient.releaseClient(client) }
}

public extension CryptonautRedisClient {
    
    public enum DataValue {
        case list([String])
        case hash([String:String])
    }
    
    public struct Data {
        public let key : String
        public let value : DataValue
        public init(key:String, value:DataValue) {
            self.key = key
            self.value = value
        }
    }
    
    public enum GetResult<T> {
        case error(Swift.Error)
        case value([T])
    }
    
    public func add(params:Data, completion:@escaping (GetResult<Data>)->Void) {
        let key = params.key
        let queue = self.queue
        let response : (RedisResponse)->Void = { response in
            queue.async {
                if case RedisResponse.error(let type, let msg) = response {
                    completion(.error(Error.redisResponseError(type: type, msg: msg)))
                    return
                }
                completion(.value([params]))
            }
        }
        
        switch params.value {
        case .list(let list):
            client.listAppend(key: key, values: list.map { return RedisClient.RedisValue.string($0) }, callback: response )
        case .hash(let hash):
            let v = hash.map { return ($0.key, RedisClient.RedisValue.string($0.value)) }
            client.hashSet(key: key, fieldsValues: v, callback: response)
        }
    }
    
    public func update(oldParams:Data, newParams:Data, completion:@escaping (GetResult<Data>)->Void) {
        
        switch (oldParams.value, newParams.value) {
        case (.list, .list):
            remove(params: oldParams) {[weak self] response in
                guard let this = self else { return }
                if case GetResult.error(let err) = response {
                    this.queue.async { completion(.error(err))}
                    return
                }
                this.add(params: newParams, completion: completion)
            }
        case (.hash, .hash):
            add(params: newParams, completion: completion)
        default:
            completion(.error(Error.typeInconsistencyError))
        }
    }
    
    public func remove(params:Data, completion:@escaping (GetResult<Data>)->Void) {
        let key = params.key
        let queue = self.queue
        switch params.value {
        case .list(let list):
            var group : DispatchGroup? = DispatchGroup()
            list.forEach {
                group?.enter()
                client.listRemoveMatching(key: key, value: RedisClient.RedisValue.string($0), count: 1, callback: { response in
                    if case RedisResponse.error(let type, let msg) = response {
                        group = nil
                        queue.async { completion(.error(Error.redisResponseError(type: type, msg: msg)))}
                    }
                    group?.leave()
                })
            }
            group?.notify(queue: queue) {
                queue.async { completion(.value([params])) }
                group = nil
            }
        case .hash(let hash):
            client.hashDel(key: key, fields: hash.keys.map { $0 }, callback: { response in
                queue.async {
                    if case RedisResponse.error(let type, let msg) = response {
                        completion(.error(Error.redisResponseError(type: type, msg: msg)))
                        return
                    }
                    completion(.value([params]))
                }
            })
        }
    }
    
    private func getDataArrayfromResponse(_ response:RedisResponse, valueType:DataValue) -> GetResult<String> {
        switch response {
        case .error(let type, let msg):
            return .error(Error.redisResponseError(type: type, msg: msg))
        case .array(let array):
            let items = array.flatMap { $0.toString() }
            return .value(items)
        default:
            return .error(Error.unexpectedResponse(response.toString()))
        }
    }
    
    public func getKeys(forParams params:Data, completion:@escaping (GetResult<String>)->Void) {
        client.keys(pattern: params.key) { [weak self] response in
            guard let this = self else { return }
            let result = this.getDataArrayfromResponse(response, valueType: params.value)
            this.queue.async { completion(result) }
        }
    }
    
    public func getData(forParams params:Data, completion:@escaping (GetResult<Data>)->Void) {
        getKeys(forParams: params) { [weak self] result in
            guard let this = self else { return }
            
            switch result {
            case .error(let error):
                completion(.error(error))
                
            case .value(let keysData):
                var group : DispatchGroup! = DispatchGroup()
                var result = [Data]()
                keysData.forEach { key in
                    group.enter()
                    this.get(params: Data(key: key, value: params.value)) {
                        defer { group?.leave() }
                        switch $0 {
                        case .error(let error):
                            completion(.error(error))
                            group = nil
                        case .value(let data):
                            result.append(contentsOf:data)
                        }
                    }
                }
                
                group.notify(queue: this.queue, execute: {
                    completion(.value(result))
                    group = nil
                })
            }
        }
    }
    
    func get(params: Data, completion:@escaping (GetResult<Data>)->Void) {
        guard !params.key.contains(string: "*") else {
            completion(.error(Error.unsupportedUseOfPatterns(params.key)))
            return
        }
        
        let key = params.key
        switch params.value {
        case .list(_):
            client.listRange(key: key, start: 0, stop: -1) {[weak self] response in
                guard let this = self else { return }
                this.queue.async {
                    switch this.getDataArrayfromResponse(response, valueType: params.value) {
                    case .error(let error):
                        completion(.error(error))
                    case .value(let result):
                        completion(.value([Data(key: params.key, value: .list(result))]))
                    }
                }
            }
            
        case .hash(_):
            client.hashGetAll(key: key) { [weak self ] response in
                
                guard let this = self else { return }
                this.queue.async {
                    switch this.getDataArrayfromResponse(response, valueType: params.value) {
                    case .error(let error):
                        completion(.error(error))
                    case .value(let dataArray):
                        var hash = [String:String]()
                        
                        dataArray.chunks(2).forEach {
                            guard $0.count == 2 else { return }
                            hash[$0[0]] = $0[1]
                        }
                        completion(.value([Data(key: key, value: .hash(hash))]))
                    }
                }
                
            }
        }
    }
}

extension CryptonautRedisClient {
    enum Error : Swift.Error {
        case couldNotSelectDatabase(String?)
        case redisResponseError(type:String, msg:String)
        case typeInconsistencyError
        case unexpectedResponse(String?)
        case unsupportedUseOfPatterns(String)
    }
}

extension Array {
    func chunks(_ chunkSize: Int) -> [[Element]] {
        return stride(from: 0, to: self.count, by: chunkSize).map {
            Array(self[$0..<Swift.min($0 + chunkSize, self.count)])
        }
    }
}
