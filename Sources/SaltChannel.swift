//  SaltChannel.swift
//  SaltChannel
//
//  Created by Håkan Olsson on 2017-05-31.

import Foundation
import Sodium
import os.log

internal struct HandshakeData {
    var serverEncPub: Data?
    var m1Hash: Data?
    var m2Hash: Data?
    var clientEncSec: Data?
    var clientEncPub: Data?

    var negotiateCompleted: ((SaltChannelProtocols) -> Void)?
    var handshakeCompleted: ((Data) -> Void)?
    var failure: ((Error) -> Void)?
}

public enum HandshakeState {
    case notStarted
    case expectM2
    case expectM3
    case expectA2
    case done
}

/**
 **SaltChannel** is a ByteChannel with encryption and authorization.
 */
public class SaltChannel: ByteChannel {
    
    let log = OSLog(subsystem: "salt.aa.st", category: "Channel")
    var timeKeeper: TimeKeeper

    let callbackQueue = DispatchQueue(label: "SaltChannel callback queue", attributes: .concurrent)
    var callbacks: [(Data) -> Void] = []
    var errorHandlers: [(Error) -> Void] = []

    let channel: ByteChannel
    let clientSignSec: Data
    let clientSignPub: Data
    var remoteSignPub: Data?

    let sodium = Sodium()
    var session: Session?

    var sendNonce = Nonce(value: 1)
    var receiveNonce = Nonce(value: 2)
    
    var handshakeData = HandshakeData()
    public var handshakeState: HandshakeState

    public convenience init (channel: ByteChannel, sec: Data, pub: Data) {
        self.init(channel: channel, sec: sec, pub: pub, timeKeeper: RealTimeKeeper())
    }
    
    /// Create a SaltChannel with channel to wrap plus the clients signing
    /// keypair.
    public init (channel: ByteChannel, sec: Data, pub: Data, timeKeeper: TimeKeeper) {
        self.timeKeeper = timeKeeper
        self.channel = channel
        self.clientSignSec = sec
        self.clientSignPub = pub
        self.handshakeState = .notStarted
        
        self.channel.register(callback: handleRead, errorhandler: propagateError)
        
        os_log("Created SaltChannel %@", log: log, type: .debug, pub as CVarArg)
    }

    // MARK: Channel
    public func write(_ data: [Data]) throws {
        guard let session = self.session else {
            throw ChannelError.setupNotDone(reason: "Expected a Session by now")
        }
        
        var appMessage = Data()
        if data.count == 1 {
            appMessage = writeApp(time: timeKeeper.time(), message: data.first!)
        } else {
            appMessage = writeMultiApp(time: timeKeeper.time(), messages: data)
        }
        
        let cipherMessage = encryptMessage(session: session, message: appMessage)
        try self.channel.write([cipherMessage])
    }
    
    public func register(callback: @escaping (Data) -> Void, errorhandler: @escaping (Error) -> Void) {
        callbackQueue.async(flags: .barrier) {
            self.errorHandlers.append(errorhandler)
            self.callbacks.append(callback)
        }
    }
    
    // --- Callbacks -------
    
    private func propagateError(_ error: Error) {
        os_log("Ended up in SaltChannel ErrorHandler: %@", log: log, type: .error, error as CVarArg)

        var safeErrorHandlers = [(Error) -> Void]()
        callbackQueue.sync {
            safeErrorHandlers = self.errorHandlers
        }
        for errorHandler in safeErrorHandlers {
            errorHandler(error)
        }
    }

    private func handleRead(_ data: Data) {
        do {
            switch self.handshakeState {

            case .notStarted:
                throw ChannelError.setupNotDone(reason: "Handshake not done yet!")
            case .expectM2:
                receiveM2(m2Raw: data)
            case .expectM3:
                receiveM3sendM4(m3Raw: data)
            case .expectA2:
                receiveA2(a2Raw: data)
            case .done:
                guard let session = self.session else {
                    throw ChannelError.setupNotDone(reason: "Expected a Session by now")
                }

                let raw = try decryptMessage(message: data, session: session)
                let (_, messages) = try unpackApp(raw)

                propagateMessages(messages)
            }
        } catch {
            propagateError(error)
        }
    }

    private func propagateMessages(_ messages: [Data]) {
        var safeCallbacks = [(Data) -> Void]()
        callbackQueue.sync {
            safeCallbacks = self.callbacks
        }
        for callback in safeCallbacks {
            for message in messages {
                callback(message)
            }
        }
    }

}
