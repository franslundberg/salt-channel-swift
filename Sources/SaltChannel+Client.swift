//  Handshake.swift
//  SaltChannel
//
//  Created by Kenneth Pernyer on 2017-10-02.

import Foundation
import CocoaLumberjack

extension SaltChannel {
    
    func handshake(holdUntilFirstWrite: Bool = false) throws {
        let encKeyPair = sodium.box.keyPair()! // ToDo: Use true random from HW
        try handshake(clientEncSec: encKeyPair.secretKey, clientEncPub: encKeyPair.publicKey, holdUntilFirstWrite: holdUntilFirstWrite)
    }
    
    func handshake(clientEncSec: Data, clientEncPub: Data, holdUntilFirstWrite: Bool = false)
        throws {
            
        self.channel.register(callback: read, errorhandler: error)
            
        let m1Hash = try m1(time: 0, myEncPub: clientEncPub)
        
        if WaitUntil.waitUntil(60, self.lastMessage != nil) {
            let m2Raw = self.lastMessage!
            self.lastMessage = nil
            let (_, serverEncPub, m2Hash) = try m2(data: m2Raw)
            
            guard let key = sodium.box.beforenm(recipientPublicKey: serverEncPub, senderSecretKey: clientEncSec) else {
                throw ChannelError.couldNotCalculateSessionKey
            }
            
            // Create a session
            self.session = Session(key: key)
            guard let session = self.session else {
                throw ChannelError.couldNotCalculateSessionKey
            }
            
            if WaitUntil.waitUntil(60, self.lastMessage != nil) {
                let m3Raw = self.lastMessage!
                self.lastMessage = nil
                
                let data: Data = try receiveAndDecryptMessage(message: m3Raw, session: session)
                
                let (m3time, remoteSignPub) = try m3(data: data, m1Hash: m1Hash, m2Hash: m2Hash)
                
                DDLogInfo("M3 received time = " + String(m3time))

                self.remoteSignPub = remoteSignPub
                
                let m4Data: Data = try m4(time: 0, clientSignSec: clientSignSec, clientSignPub: clientSignPub, m1Hash: m1Hash, m2Hash: m2Hash)
                
                self.handshakeDone = true
                
                if holdUntilFirstWrite {
                    bufferedM4 = encryptMessage(session: session, message: m4Data)
                } else {
                    try encryptAndSendMessage(session: session, message: m4Data)
                }
            } else {
                throw ChannelError.readTimeout
            }
        } else {
            throw ChannelError.readTimeout
        }
    }
    
    public func gotHandshakeMessage(message: Data){
        self.lastMessage = message
    }
}