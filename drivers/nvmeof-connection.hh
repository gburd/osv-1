/*
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef NVMEOF_CONNECTION_HH
#define NVMEOF_CONNECTION_HH

#include <string>
#include <memory>
#include <mutex>
#include <vector>
#include <cstdint>
#include <system_error>

namespace nvmeof {

/**
 * TCP connection wrapper for NVMe/TCP target communication.
 *
 * Handles low-level TCP socket operations including connection
 * establishment, send/receive, and connection management.
 *
 * Thread-safety: send_exact() and recv_exact() each take an internal
 * mutex that serialises calls on a single Connection.  This is necessary
 * because the NVMe/TCP wire protocol frames a single PDU (its common
 * header immediately followed by the PDU-specific header and any data)
 * across one or more send() syscalls, and OSv's block layer issues I/O
 * from many threads concurrently; without per-direction locks the target
 * sees interleaved bytes and resets the connection.  Send and receive use
 * independent mutexes so a long send cannot block a reader from draining
 * responses.
 */
class Connection {
public:
    /**
     * Create a connection to an NVMe/TCP target.
     *
     * @param host Hostname or IP address
     * @param port TCP port number
     * @throws ConnectionError on connection failure
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
     * Send data over the connection (single syscall, may be partial).
     *
     * @param buf Buffer to send
     * @param len Length of buffer
     * @return Number of bytes sent
     * @throws ConnectionError on send failure
     */
    ssize_t send(const void* buf, size_t len);

    /**
     * Send exact amount of data, looping until all bytes are sent.
     *
     * @param buf Buffer to send
     * @param len Exact number of bytes to send
     * @throws ConnectionError on send failure or EOF
     */
    void send_exact(const void* buf, size_t len);

    /**
     * Send a header buffer immediately followed by a separate data
     * buffer as a single atomic message on the socket.  Used for
     * H2CData PDUs where the PDU header and its data payload must reach
     * the wire back-to-back without another thread's bytes intervening.
     *
     * @param header  PDU header buffer
     * @param hlen    Length of header buffer
     * @param data    Bulk data buffer
     * @param dlen    Length of bulk data
     * @throws ConnectionError on send failure or EOF
     */
    void send_exact_with_data(const void* header, size_t hlen,
                              const void* data, size_t dlen);

    /**
     * Receive data from the connection.
     *
     * Blocks until at least some data is available.
     *
     * @param buf Buffer to receive into
     * @param len Maximum bytes to receive
     * @return Number of bytes received (0 on EOF)
     * @throws ConnectionError on receive failure
     */
    ssize_t recv(void* buf, size_t len);

    /**
     * Receive exact amount of data.
     *
     * Blocks until all requested data is received.
     *
     * @param buf Buffer to receive into
     * @param len Exact number of bytes to receive
     * @throws ConnectionError on receive failure or EOF
     */
    void recv_exact(void* buf, size_t len);

    /**
     * Check if connection is established.
     *
     * @return true if connected, false otherwise
     */
    bool is_connected() const;

    /**
     * Close and reconnect to the same host:port.
     *
     * Re-applies SO_KEEPALIVE settings.  Throws ConnectionError on
     * failure.  After this returns successfully, is_connected() is true.
     */
    void reconnect();

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
    /* Loop until len bytes are sent.  Caller must hold send_lock_. */
    void send_all_locked(const void* buf, size_t len);

    int fd_{-1};
    std::string host_;
    uint16_t port_;
    bool connected_{false};

    /*
     * Serialise concurrent send / recv calls.  send_lock_ ensures one
     * thread's header+data pair reaches the wire as a contiguous PDU;
     * recv_lock_ ensures a reader sees one complete PDU at a time.
     * They're independent so a slow send does not block response
     * processing.
     */
    mutable std::mutex send_lock_;
    mutable std::mutex recv_lock_;
};

/**
 * Exception thrown for NVMe/TCP connection errors.
 */
class ConnectionError : public std::runtime_error {
public:
    explicit ConnectionError(const std::string& msg)
        : std::runtime_error(msg) {}
};

} // namespace nvmeof

#endif // NVMEOF_CONNECTION_HH
