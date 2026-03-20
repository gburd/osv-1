/*
 * Copyright (C) 2024 Waldemar Kozaczuk
 * Copyright (C) 2024 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef CRUCIBLE_CONNECTION_HH
#define CRUCIBLE_CONNECTION_HH

#include <string>
#include <memory>
#include <vector>
#include <cstdint>
#include <system_error>

namespace crucible {

/**
 * TCP connection wrapper for Crucible downstairs communication.
 *
 * Handles low-level TCP socket operations including connection establishment,
 * send/receive, and connection management.
 *
 * Thread-safety: Not thread-safe. External synchronization required.
 */
class Connection {
public:
    /**
     * Create a connection to a Crucible downstairs server.
     *
     * @param host Hostname or IP address
     * @param port TCP port number
     * @throws std::system_error on connection failure
     */
    Connection(const std::string& host, uint16_t port);

    /**
     * Destructor - closes connection if open.
     */
    ~Connection();

    // Non-copyable, movable
    Connection(const Connection&) = delete;
    Connection& operator=(const Connection&) = delete;
    Connection(Connection&&) noexcept;
    Connection& operator=(Connection&&) noexcept;

    /**
     * Send data over the connection.
     *
     * @param buf Buffer to send
     * @param len Length of buffer
     * @return Number of bytes sent
     * @throws std::system_error on send failure
     */
    ssize_t send(const void* buf, size_t len);

    /**
     * Receive data from the connection.
     *
     * Blocks until at least some data is available.
     *
     * @param buf Buffer to receive into
     * @param len Maximum bytes to receive
     * @return Number of bytes received (0 on EOF)
     * @throws std::system_error on receive failure
     */
    ssize_t recv(void* buf, size_t len);

    /**
     * Receive exact amount of data.
     *
     * Blocks until all requested data is received.
     *
     * @param buf Buffer to receive into
     * @param len Exact number of bytes to receive
     * @throws std::system_error on receive failure or EOF
     */
    void recv_exact(void* buf, size_t len);

    /**
     * Check if connection is established.
     *
     * @return true if connected, false otherwise
     */
    bool is_connected() const;

    /**
     * Close the connection.
     *
     * Safe to call multiple times.
     */
    void close();

    /**
     * Get the file descriptor.
     *
     * @return Socket file descriptor (-1 if not connected)
     */
    int fd() const { return fd_; }

private:
    int fd_{-1};
    std::string host_;
    uint16_t port_;
    bool connected_{false};
};

/**
 * Exception thrown for Crucible connection errors.
 */
class ConnectionError : public std::runtime_error {
public:
    explicit ConnectionError(const std::string& msg)
        : std::runtime_error(msg) {}
};

} // namespace crucible

#endif // CRUCIBLE_CONNECTION_HH
