/*
 * Copyright (C) 2024 Waldemar Kozaczuk
 * Copyright (C) 2024 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include "crucible-connection.hh"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <cstring>
#include <stdexcept>

namespace crucible {

Connection::Connection(const std::string& host, uint16_t port)
    : host_(host), port_(port)
{
    // Create socket
    fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (fd_ < 0) {
        throw ConnectionError("Failed to create socket: " +
                            std::string(strerror(errno)));
    }

    // Resolve hostname
    struct addrinfo hints{};
    struct addrinfo* result = nullptr;

    hints.ai_family = AF_INET;  // IPv4 for now
    hints.ai_socktype = SOCK_STREAM;

    std::string port_str = std::to_string(port);
    int rv = getaddrinfo(host.c_str(), port_str.c_str(), &hints, &result);
    if (rv != 0) {
        ::close(fd_);
        fd_ = -1;
        throw ConnectionError("Failed to resolve host: " +
                            std::string(gai_strerror(rv)));
    }

    // Try to connect
    bool connected = false;
    for (struct addrinfo* rp = result; rp != nullptr; rp = rp->ai_next) {
        if (connect(fd_, rp->ai_addr, rp->ai_addrlen) == 0) {
            connected = true;
            break;
        }
    }

    freeaddrinfo(result);

    if (!connected) {
        int saved_errno = errno;
        ::close(fd_);
        fd_ = -1;
        throw ConnectionError("Failed to connect to " + host + ":" +
                            port_str + ": " + strerror(saved_errno));
    }

    connected_ = true;
}

Connection::~Connection()
{
    close();
}

Connection::Connection(Connection&& other) noexcept
    : fd_(other.fd_)
    , host_(std::move(other.host_))
    , port_(other.port_)
    , connected_(other.connected_)
{
    other.fd_ = -1;
    other.connected_ = false;
}

Connection& Connection::operator=(Connection&& other) noexcept
{
    if (this != &other) {
        close();

        fd_ = other.fd_;
        host_ = std::move(other.host_);
        port_ = other.port_;
        connected_ = other.connected_;

        other.fd_ = -1;
        other.connected_ = false;
    }
    return *this;
}

ssize_t Connection::send(const void* buf, size_t len)
{
    if (!connected_) {
        throw ConnectionError("Not connected");
    }

    ssize_t sent = ::send(fd_, buf, len, 0);
    if (sent < 0) {
        int saved_errno = errno;
        connected_ = false;
        throw ConnectionError("Send failed: " + std::string(strerror(saved_errno)));
    }

    return sent;
}

ssize_t Connection::recv(void* buf, size_t len)
{
    if (!connected_) {
        throw ConnectionError("Not connected");
    }

    ssize_t received = ::recv(fd_, buf, len, 0);
    if (received < 0) {
        int saved_errno = errno;
        connected_ = false;
        throw ConnectionError("Recv failed: " + std::string(strerror(saved_errno)));
    }

    if (received == 0) {
        // EOF - connection closed by peer
        connected_ = false;
    }

    return received;
}

void Connection::recv_exact(void* buf, size_t len)
{
    size_t total_received = 0;
    uint8_t* ptr = static_cast<uint8_t*>(buf);

    while (total_received < len) {
        ssize_t n = recv(ptr + total_received, len - total_received);
        if (n == 0) {
            throw ConnectionError("Connection closed before receiving all data");
        }
        total_received += n;
    }
}

bool Connection::is_connected() const
{
    return connected_;
}

void Connection::close()
{
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    connected_ = false;
}

} // namespace crucible
