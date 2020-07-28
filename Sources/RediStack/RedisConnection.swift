//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2019 RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.UUID
import struct Dispatch.DispatchTime
import Logging
import Metrics
import NIO
import NIOConcurrencyHelpers

extension RedisConnection {
    /// The documented default port that Redis connects through.
    ///
    /// See [https://redis.io/topics/quickstart](https://redis.io/topics/quickstart)
    public static let defaultPort = 6379
    
    /// Creates a new connection to a Redis instance.
    ///
    /// If you would like to specialize the `NIO.ClientBootstrap` that the connection communicates on, override the default by passing it in as `tcpClient`.
    ///
    ///     let eventLoopGroup: EventLoopGroup = ...
    ///     var customTCPClient = ClientBootstrap.makeRedisTCPClient(group: eventLoopGroup)
    ///     customTCPClient.channelInitializer { channel in
    ///         // channel customizations
    ///     }
    ///     let connection = RedisConnection.connect(
    ///         to: ...,
    ///         on: eventLoopGroup.next(),
    ///         password: ...,
    ///         tcpClient: customTCPClient
    ///     ).wait()
    ///
    /// It is recommended that you be familiar with `ClientBootstrap.makeRedisTCPClient(group:)` and `NIO.ClientBootstrap` in general before doing so.
    ///
    /// Note: Use of `wait()` in the example is for simplicity. Never call `wait()` on an event loop.
    ///
    /// - Important: Call `close()` on the connection before letting the instance deinit to properly cleanup resources.
    /// - Note: If a `password` is provided, the connection will send an "AUTH" command to Redis as soon as it has been opened.
    ///
    /// - Parameters:
    ///     - socket: The `NIO.SocketAddress` information of the Redis instance to connect to.
    ///     - eventLoop: The `NIO.EventLoop` that this connection will execute all tasks on.
    ///     - password: The optional password to use for authorizing the connection with Redis.
    ///     - logger: The `Logging.Logger` instance to use for all client logging purposes. If one is not provided, one will be created.
    ///         A `Foundation.UUID` will be attached to the metadata to uniquely identify this connection instance's logs.
    ///     - tcpClient: If you have chosen to configure a `NIO.ClientBootstrap` yourself, this will be used instead of the `makeRedisTCPClient` instance.
    /// - Returns: A `NIO.EventLoopFuture` that resolves with the new connection after it has been opened, and if a `password` is provided, authenticated.
    public static func connect(
        to socket: SocketAddress,
        on eventLoop: EventLoop,
        password: String? = nil,
        logger: Logger = .init(label: "RediStack.RedisConnection"),
        tcpClient: ClientBootstrap? = nil
    ) -> EventLoopFuture<RedisConnection> {
        let client = tcpClient ?? ClientBootstrap.makeRedisTCPClient(group: eventLoop)
        
        return client.connect(to: socket)
            .map { return RedisConnection(configuredRESPChannel: $0, logger: logger) }
            .flatMap { connection in
                guard let pw = password else {
                    return connection.eventLoop.makeSucceededFuture(connection)
                }
                return connection.authorize(with: pw)
                    .map { return connection }
            }
    }
}

/// A concrete `RedisClient` implementation that represents an individual connection to a Redis database instance.
///
/// For basic setups, you will just need a  `NIO.SocketAddress` and a `NIO.EventLoop` and perhaps a `password`.
///
///     let eventLoop: EventLoop = ...
///     let connection = RedisConnection.connect(
///         to: try .makeAddressResolvingHost("my.redis.url", port: RedisConnection.defaultPort),
///         on: eventLoop
///     ).wait()
///
///     let result = try connection.set("my_key", to: "some value")
///         .flatMap { return connection.get("my_key") }
///         .wait()
///
///     print(result) // Optional("some value")
///
/// Note: `wait()` is used in the example for simplicity. Never call `wait()` on an event loop.
///
/// See `NIO.SocketAddress`, `NIO.EventLoop`, and `RedisClient`
public final class RedisConnection: RedisClient {
    /// A unique identifer to represent this connection.
    public let id = UUID()
    public private(set) var logger: Logger {
        didSet {
            self.logger[metadataKey: String(describing: RedisConnection.self)] = .string(self.id.description)
        }
    }
    public var eventLoop: EventLoop { return self.channel.eventLoop }
    /// Is the connection to Redis still open?
    public var isConnected: Bool {
        // `Channel.isActive` is set to false before the `closeFuture` resolves in cases where the channel might be
        // closed, or closing, before our state has been updated
        return self.channel.isActive && self.state == .open
    }
    /// Controls the behavior of when sending commands over this connection. The default is `true.
    ///
    /// When set to `false`, the commands will be placed into a buffer, and the host machine will determine when to drain the buffer.
    /// When set to `true`, the buffer will be drained as soon as commands are added.
    /// - Important: Even when set to `true`, the host machine may still choose to delay sending commands.
    /// - Note: Setting this to `true` will immediately drain the buffer.
    public var sendCommandsImmediately: Bool {
        get { return autoflush.load() }
        set(newValue) {
            if newValue { self.channel.flush() }
            autoflush.store(newValue)
        }
    }
    
    internal let channel: Channel
    
    private let autoflush: NIOAtomic<Bool> = .makeAtomic(value: true)
    private let _stateLock = Lock()
    private var _state = ConnectionState.open
    private var state: ConnectionState {
        get { return _stateLock.withLock { self._state } }
        set(newValue) { _stateLock.withLockVoid { self._state = newValue } }
    }
    
    deinit {
        if isConnected {
            assertionFailure("close() was not called before deinit!")
            logger.warning("RedisConnection did not properly shutdown before deinit!")
        }
    }
    
    internal init(configuredRESPChannel: Channel, logger: Logger) {
        self.channel = configuredRESPChannel
        self.logger = logger

        RedisMetrics.activeConnectionCount.increment()
        RedisMetrics.totalConnectionCount.increment()
        
        // attach a callback to the channel to capture situations where the channel might be closed out from under
        // the connection
        self.channel.closeFuture.whenSuccess {
            // if our state is still open, that means we didn't cause the closeFuture to resolve.
            // update state, metrics, and logging
            guard self.state == .open else { return }
            
            self.state = .closed
            self.logger.error("Channel was closed unexpectedly.")
            RedisMetrics.activeConnectionCount.decrement()
        }

        self.logger.trace("Connection created.")
    }
    
    internal enum ConnectionState {
        case open
        case shuttingDown
        case closed
    }
}

// MARK: Sending Commands

extension RedisConnection {
    /// Sends the command with the provided arguments to Redis.
    ///
    /// See `RedisClient.send(command:with:)`.
    ///
    /// - Note: The timing of when commands are actually sent to Redis can be controlled with the `RedisConnection.sendCommandsImmediately` property.
    /// - Returns: A `NIO.EventLoopFuture` that resolves with the command's result stored in a `RESPValue`.
    ///     If a `RedisError` is returned, the future will be failed instead.
    public func send(command: String, with arguments: [RESPValue]) -> EventLoopFuture<RESPValue> {
        self.logger.trace("Received command")

        guard self.isConnected else {
            let error = RedisClientError.connectionClosed
            logger.warning("\(error.localizedDescription)")
            return self.channel.eventLoop.makeFailedFuture(error)
        }
        
        var message: [RESPValue] = [.init(bulk: command)]
        message.append(contentsOf: arguments)
        
        let promise = channel.eventLoop.makePromise(of: RESPValue.self)
        let promiseCluster = channel.eventLoop.makePromise(of: RESPValue.self)
        let redisCommand = RedisCommand(
            message: .array(message),
            responsePromise: promise
        )
        
        let startTime = DispatchTime.now().uptimeNanoseconds
        promise.futureResult.whenComplete { result in
            let duration = DispatchTime.now().uptimeNanoseconds - startTime
            RedisMetrics.commandRoundTripTime.recordNanoseconds(duration)
            
            // log the error here instead
            switch result {
            case .success(let value):
                promiseCluster.succeed(value)
                self.logger.trace("Command completed.")
            case .failure(let error):
                if error.localizedDescription.contains("MOVED") {
                    guard let ipPort = error.localizedDescription.components(separatedBy: .whitespaces)
                        .last?
                        .components(separatedBy: ":") else {

                            promiseCluster.fail(error)
                            return
                    }
                    guard let ip = ipPort.first,
                        let portStr = ipPort.last,
                        let port = Int(portStr) else {

                            promiseCluster.fail(error)
                            return
                    }
                    do {
                        _ = RedisConnection.connect(to: try .makeAddressResolvingHost(ip, port: port),
                                                    on: self.channel.eventLoop)
                            .map { $0.send(command: command, with: arguments).map { promiseCluster.succeed($0) }}
                    } catch let error {
                        promiseCluster.fail(error)
                    }
                } else {
                    self.logger.error("\(error.localizedDescription)")
                }
            }
        }
        
        self.logger.debug("Sending command \"\(redisCommand)\"\(arguments.count > 0 ? " with \(arguments)" : "")")
        
        defer { self.logger.trace("Command sent through channel.") }

        if self.sendCommandsImmediately {
            return channel.writeAndFlush(redisCommand).and(promiseCluster.futureResult).flatMap { _ in
                promiseCluster.futureResult
            }
        } else {
            return channel.write(redisCommand).and(promiseCluster.futureResult).flatMap { _ in
                promiseCluster.futureResult
            }
        }
    }
}

// MARK: Closing a Connection

extension RedisConnection {
    /// Sends a `QUIT` command to Redis, then closes the `NIO.Channel` that supports this connection.
    ///
    /// See [https://redis.io/commands/quit](https://redis.io/commands/quit)
    /// - Important: Regardless if the returned `NIO.EventLoopFuture` fails or succeeds - after calling this method the connection should no longer be
    ///     used for sending commands to Redis.
    /// - Returns: A `NIO.EventLoopFuture` that resolves when the connection has been closed.
    @discardableResult
    public func close() -> EventLoopFuture<Void> {
        self.logger.trace("Received request to close the connection.")

        guard self.isConnected else {
            // return the channel's close future, which is resolved as the last step in channel shutdown
            return self.channel.closeFuture
        }

        // we're now in a shutdown state, starting with the command queue.
        self.state = .shuttingDown
        
        let notification = self.sendQuitCommand() // send "QUIT" so that all the responses are written out
            .flatMap { self.closeChannel() } // close the channel from our end
        
        notification.whenFailure { self.logger.error("Encountered error during close(): \($0)") }
        notification.whenSuccess {
            self.state = .closed
            self.logger.debug("Connection closed.")
            RedisMetrics.activeConnectionCount.decrement()
        }
        
        return notification
    }
    
    /// Bypasses everything for a normal command and explicitly just sends a "QUIT" command to Redis.
    /// - Note: If the command fails, the `NIO.EventLoopFuture` will still succeed - as it's not critical for the command to succeed.
    private func sendQuitCommand() -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: RESPValue.self)
        let command = RedisCommand(
            message: .array([RESPValue(bulk: "QUIT")]),
            responsePromise: promise
        )

        logger.trace("Sending QUIT command.")

        return channel.writeAndFlush(command) // write the command
            .flatMap { promise.futureResult } // chain the callback to the response's
            .map { _ in () } // ignore the result's value
            .recover { _ in () } // if there's an error, just return to void
    }
    
    /// Attempts to close the `NIO.Channel`.
    /// SwiftNIO throws a `NIO.EventLoopError.shutdown` if the channel is already closed,
    /// so that case is captured to let this method's `NIO.EventLoopFuture` still succeed.
    private func closeChannel() -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        
        self.channel.close(promise: promise)
     
        // if we succeed, great, if not - check the error that happened
        return promise.futureResult
            .flatMapError { error in
                guard let e = error as? EventLoopError else {
                    return self.eventLoop.makeFailedFuture(error)
                }
                
                // if the error is that the channel is already closed, great - just succeed.
                // otherwise, fail the chain
                switch e {
                case .shutdown: return self.eventLoop.makeSucceededFuture(())
                default: return self.eventLoop.makeFailedFuture(e)
                }
            }
    }
}

// MARK: Logging

extension RedisConnection {
    /// Updates the client's logger, attaching this connection's ID to the metadata.
    ///
    /// See `RedisClient.setLogging(to:)` and `RedisConnection.id`.
    /// - Parameter logger: The `Logging.Logger` that is desired to receive all client logs.
    public func setLogging(to logger: Logger) {
        self.logger = logger
    }
}
