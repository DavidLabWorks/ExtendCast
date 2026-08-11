#include "NetworkListener.h"
#include "MainWindow.h"  // for LogManager
#include "NetworkInterfaceDescription.h"
#include "ReceiverRouteClassifier.h"
#include "VideoPacket.h"

#include <QHostAddress>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkInterface>
#include <QPointer>
#include <QUuid>
#include <QtEndian>
#include <vector>

NetworkListener::NetworkListener(QObject* parent)
    : QObject(parent)
    , m_lastKeyframeRequest(QDateTime::fromMSecsSinceEpoch(0))
    , m_lastStatsTime(QDateTime::currentDateTime())
{
    m_videoTimelineClock.start();
}

NetworkListener::~NetworkListener() {
    stop();
}

uint16_t NetworkListener::actualTcpPort() const {
    if (m_tcpServer && m_tcpServer->isListening())
        return m_tcpServer->serverPort();
    return kDefaultTcpPort;
}

void NetworkListener::start() {
    if (isListening()) {
        emit statusChanged(QString("Listening on port %1").arg(actualTcpPort()));
        return;
    }

    // Start TCP server
    m_tcpServer = new QTcpServer(this);
    connect(m_tcpServer, &QTcpServer::newConnection, this, &NetworkListener::onNewTcpConnection);

    if (m_tcpServer->listen(QHostAddress::Any, kDefaultTcpPort)) {
        LogManager::instance().log(QString("TCP listening on port %1").arg(m_tcpServer->serverPort()));
        emit statusChanged(QString("Listening on port %1").arg(m_tcpServer->serverPort()));
    } else {
        LogManager::instance().log(QString("TCP port %1 unavailable: %2 — trying system-assigned port")
                                       .arg(kDefaultTcpPort).arg(m_tcpServer->errorString()));
        // Try any available port if default is taken
        if (m_tcpServer->listen(QHostAddress::Any, 0)) {
            LogManager::instance().log(QString("TCP listening on fallback port %1").arg(m_tcpServer->serverPort()));
            emit statusChanged(QString("Listening on port %1 (fallback)").arg(m_tcpServer->serverPort()));
        } else {
            qWarning() << "TCP listen failed:" << m_tcpServer->errorString();
            emit statusChanged("TCP listen failed: " + m_tcpServer->errorString());
        }
    }

    // Start UDP socket
    m_udpSocket = new QUdpSocket(this);
    if (m_udpSocket->bind(QHostAddress::Any, kDefaultUdpPort)) {
        connect(m_udpSocket, &QUdpSocket::readyRead, this, &NetworkListener::onUdpReadyRead);
        qDebug() << "UDP listening on port" << kDefaultUdpPort;
    } else {
        qWarning() << "UDP bind failed:" << m_udpSocket->errorString();
    }

    // Heartbeat timer (every 500ms, matching Swift receiver)
    m_heartbeatTimer = new QTimer(this);
    connect(m_heartbeatTimer, &QTimer::timeout, this, &NetworkListener::onHeartbeatTick);
    m_heartbeatTimer->start(500);
}

void NetworkListener::stop() {
    disconnectAll();

    if (m_heartbeatTimer) {
        m_heartbeatTimer->stop();
        delete m_heartbeatTimer;
        m_heartbeatTimer = nullptr;
    }

    if (m_udpSocket) {
        m_udpSocket->close();
        delete m_udpSocket;
        m_udpSocket = nullptr;
    }

    if (m_tcpServer) {
        m_tcpServer->close();
        delete m_tcpServer;
        m_tcpServer = nullptr;
    }

    {
        QMutexLocker lock(&m_udpMutex);
        m_udpBuffer.clear();
    }
}

bool NetworkListener::isListening() const {
    return m_tcpServer && m_tcpServer->isListening();
}

void NetworkListener::disconnectAll() {
    for (auto* client : m_clients) {
        client->disconnect(); // disconnect signals
        client->abort();
        client->deleteLater();
    }
    m_clients.clear();
    m_tcpBuffers.clear();
    m_identifiedConnections.clear();
    m_connectionIds.clear();
    m_connectionRoutes.clear();
    m_socketsByConnectionId.clear();
    m_lastTcpCatchUpCheck.clear();
    m_lastTcpKeyframeRequest.clear();
    m_waitingForVideoKeyframe.clear();
    m_videoTimelines.clear();
    m_inboundSessions.clear();
}

/*
 * Intentional receiver disconnect contract
 * -----------------------------------------
 * A user closing a Receiving window and a user pressing Disconnect in the
 * tray are the same product action. Both routes arrive here while the sender
 * identity is still registered and while its TCP socket is still writable.
 *
 * The receiver first sends command 555. The sender treats that command as a
 * user decision: it removes the connection pipeline, stops screen capture,
 * invalidates the encoder, destroys its virtual display, and suppresses
 * automatic reconnect for this receiver. This is deliberately different from
 * a transport failure. A Wi-Fi or Thunderbolt interruption carries no command,
 * so the sender remains free to reconnect automatically.
 *
 * Command events use the protocol's critical-event repetition. Repetition is
 * harmless because sender teardown is idempotent, and it improves delivery on
 * noisy links. disconnectFromHost() is required here instead of abort(): Qt
 * drains queued bytes before sending FIN, whereas abort() can discard command
 * 555 and make an intentional close indistinguishable from a network failure.
 *
 * MainWindow tears down decoder and renderer objects only after calling this
 * method. That ordering prevents slow GPU cleanup from delaying the control
 * command or starving the heartbeat timer. NetworkListener remains the sole
 * owner of socket/session bookkeeping; onTcpDisconnected performs the normal
 * registry cleanup and emits connectionLost exactly as it does for any other
 * closed transport.
 *
 * This method intentionally does nothing for an unknown device ID. That makes
 * duplicate UI requests safe: closing a window can race a tray click or a peer
 * disconnect, but only the first request finds an active binding and writes to
 * the socket. Later requests simply observe that the binding has gone away.
 */
void NetworkListener::disconnectDevice(const QString& deviceId) {
    const auto binding =
        m_inboundSessions.sessionForDevice(deviceId.toStdString());
    if (!binding.has_value()) {
        return;
    }

    const QString connectionId =
        QString::fromStdString(binding->connectionId);
    if (auto* socket = m_socketsByConnectionId.value(connectionId)) {
        LogManager::instance().log(
            QString("Receiver: Disconnecting %1 from the tray")
                .arg(deviceId.left(8))
        );
        // Tell the sender this is an intentional receiver-side disconnect so
        // its auto-connect policy can pause. disconnectFromHost() drains these
        // control packets before closing, unlike abort(), which discards them.
        writeInputEvent(
            socket,
            InputEvent(
                InputEventType::Command,
                0,
                0,
                kReceiverRequestedDisconnectKeyCode
            )
        );
        socket->disconnectFromHost();
    }
}

void NetworkListener::adoptConnectedRemoteSender(QTcpSocket* socket) {
    if (!socket || socket->state() != QAbstractSocket::ConnectedState) {
        return;
    }
    socket->setParent(this);
    adoptInboundSocket(
        socket,
        "Compatibility TCP connected to "
            + socket->peerAddress().toString()
    );
}

void NetworkListener::adoptInboundSocket(
    QTcpSocket* socket,
    const QString& logDescription
) {
    registerSocket(socket);
    connect(socket, &QTcpSocket::readyRead, this, &NetworkListener::onTcpReadyRead);
    connect(socket, &QTcpSocket::disconnected, this, &NetworkListener::onTcpDisconnected);
    LogManager::instance().log(logDescription + " — waiting for sender identity");
}

void NetworkListener::onNewTcpConnection() {
    while (m_tcpServer->hasPendingConnections()) {
        auto* socket = m_tcpServer->nextPendingConnection();
        socket->setSocketOption(QAbstractSocket::LowDelayOption, 1);
        socket->setSocketOption(QAbstractSocket::KeepAliveOption, 1);

        qDebug() << "New TCP connection from" << socket->peerAddress().toString();
        adoptInboundSocket(
            socket,
            "TCP accepted from " + socket->peerAddress().toString()
        );
    }
}

QString NetworkListener::connectionIdFor(QTcpSocket* socket) const {
    return m_connectionIds.value(socket);
}

ReceiverAdvertisedRoute NetworkListener::connectionRouteFor(
    QTcpSocket* socket
) const {
    if (!socket) return ReceiverAdvertisedRoute::excluded;

    bool hasLocalIpv4 = false;
    const quint32 localIpv4 = socket->localAddress().toIPv4Address(
        &hasLocalIpv4
    );
    if (!hasLocalIpv4) return ReceiverAdvertisedRoute::excluded;

    for (const auto& iface : QNetworkInterface::allInterfaces()) {
        std::vector<std::string> ipv4Addresses;
        bool ownsLocalAddress = false;
        for (const auto& entry : iface.addressEntries()) {
            bool hasInterfaceIpv4 = false;
            const quint32 interfaceIpv4 =
                entry.ip().toIPv4Address(&hasInterfaceIpv4);
            if (!hasInterfaceIpv4) continue;
            ipv4Addresses.push_back(entry.ip().toString().toStdString());
            ownsLocalAddress = ownsLocalAddress
                || interfaceIpv4 == localIpv4;
        }
        if (!ownsLocalAddress) continue;

        return classifyReceiverAdvertisedRoute(
            detailedNetworkInterfaceDescription(iface).toStdString(),
            ipv4Addresses,
#ifdef _WIN32
            true
#else
            false
#endif
        );
    }
    return ReceiverAdvertisedRoute::excluded;
}

QString NetworkListener::connectionModeFor(QTcpSocket* socket) const {
    const auto routeIt = m_connectionRoutes.constFind(socket);
    const auto route = routeIt != m_connectionRoutes.cend()
        ? routeIt.value()
        : connectionRouteFor(socket);
    switch (route) {
    case ReceiverAdvertisedRoute::wifi:
        return "Wi-Fi";
    case ReceiverAdvertisedRoute::ethernet:
        return "Ethernet";
    case ReceiverAdvertisedRoute::thunderbolt:
        return "Thunderbolt Bridge";
    case ReceiverAdvertisedRoute::excluded:
        return "Local Network";
    }
    return "Local Network";
}

void NetworkListener::registerSocket(QTcpSocket* socket) {
    if (!socket || m_connectionIds.contains(socket)) {
        return;
    }
    const QString connectionId =
        QUuid::createUuid().toString(QUuid::WithoutBraces).toLower();
    const QString peerAddress = socket->peerAddress().toString();

    m_clients.append(socket);
    m_tcpBuffers[socket] = QByteArray();
    m_connectionIds[socket] = connectionId;
    m_connectionRoutes[socket] = connectionRouteFor(socket);
    m_socketsByConnectionId[connectionId] = socket;
    m_inboundSessions.open(
        connectionId.toStdString(),
        peerAddress.toStdString(),
        peerAddress.toStdString()
    );
}

void NetworkListener::onTcpReadyRead() {
    auto* socket = qobject_cast<QTcpSocket*>(sender());
    if (!socket) return;

    QByteArray& buffer = m_tcpBuffers[socket];
    buffer.append(socket->readAll());
    catchUpStaleTcpVideo(socket, buffer);

    // Safety: if buffer grows beyond 32MB, framing is likely desynced — reset
    if (buffer.size() > kMaxBufferSize) {
        qWarning() << "TCP buffer exceeded" << (kMaxBufferSize / (1024*1024))
                    << "MB — likely framing desync, resetting";
        buffer.clear();
        return;
    }

    processTcpBuffer(socket);
}

void NetworkListener::catchUpStaleTcpVideo(
    QTcpSocket* socket,
    QByteArray& buffer
) {
    if (!m_identifiedConnections.contains(socket) || buffer.isEmpty()) {
        return;
    }
    // While waiting for a remote IDR, do not discard arriving keyframe bytes
    // against a racing live clock — that is the backlog→flush death spiral.
    if (m_waitingForVideoKeyframe.contains(socket)) {
        return;
    }

    const QDateTime now = QDateTime::currentDateTime();
    if (m_lastTcpCatchUpCheck.contains(socket)
        && m_lastTcpCatchUpCheck[socket].msecsTo(now)
            < kTcpCatchUpCheckIntervalMs) {
        return;
    }
    m_lastTcpCatchUpCheck[socket] = now;

    std::optional<video_packet::LivePosition> livePosition;
    if (m_videoTimelines.contains(socket)) {
        const VideoTimeline& timeline = m_videoTimelines[socket];
        livePosition = video_packet::LivePosition{
            timeline.streamId,
            timeline.anchorPts
                + static_cast<std::uint64_t>(
                    m_videoTimelineClock.nsecsElapsed()
                    - timeline.anchorReceiverNanoseconds
                ),
        };
    }

    const auto preferredBufferedVideoNanoseconds =
        preferredBufferedVideoNanosecondsFor(
            m_connectionRoutes.value(
                socket,
                ReceiverAdvertisedRoute::excluded
            )
        );
    const auto decision = video_packet::planTcpVideoCatchUp(
        reinterpret_cast<const std::uint8_t*>(buffer.constData()),
        static_cast<std::size_t>(buffer.size()),
        preferredBufferedVideoNanoseconds,
        kMaximumBufferedVideoNanoseconds,
        kMaxPacketSize,
        livePosition
    );

    const auto binding = m_inboundSessions.sessionForConnection(
        connectionIdFor(socket).toStdString()
    );
    if (!binding.has_value()) {
        return;
    }
    const QString deviceId = QString::fromStdString(binding->deviceId);

    if (decision.discardBytes > 0) {
        buffer.remove(
            0,
            static_cast<qsizetype>(decision.discardBytes)
        );
        const QString action = decision.requestKeyframe
            ? QStringLiteral(
                "discarded stale packets and is waiting for a fresh keyframe"
            )
            : QStringLiteral(
                "discarded stale packets and resumed at the latest keyframe"
            );
        LogManager::instance().log(
            QString("Receiver: Video backlog reached %1 ms "
                    "(preferred %2 ms, hard limit %3 ms); %4")
                .arg(static_cast<qulonglong>(
                    decision.bufferedDurationNanoseconds / 1'000'000
                ))
                .arg(static_cast<qulonglong>(
                    preferredBufferedVideoNanoseconds / 1'000'000
                ))
                .arg(static_cast<qulonglong>(
                    kMaximumBufferedVideoNanoseconds / 1'000'000
                ))
                .arg(action)
        );
        if (decision.requestKeyframe) {
            emit videoStreamCatchUpWaitingForKeyframe(deviceId);
        } else {
            emit videoStreamCatchUpToKeyframe(deviceId);
        }
    }

    if (decision.resumeLivePosition.has_value()) {
        m_videoTimelines[socket] = VideoTimeline{
            decision.resumeLivePosition->streamId,
            decision.resumeLivePosition
                ->expectedPresentationTimestampNanoseconds,
            m_videoTimelineClock.nsecsElapsed(),
        };
    }

    if (!decision.requestKeyframe) {
        return;
    }
    m_waitingForVideoKeyframe.insert(socket);
    // Stop the wall-clock live estimate so the recovery IDR is not measured
    // as already-stale the moment it lands.
    m_videoTimelines.remove(socket);
    if (m_lastTcpKeyframeRequest.contains(socket)
        && m_lastTcpKeyframeRequest[socket].msecsTo(now)
            < kTcpKeyframeRequestIntervalMs) {
        return;
    }

    m_lastTcpKeyframeRequest[socket] = now;
    LogManager::instance().log(
        QString("Receiver: Video backlog reached %1 ms "
                "(preferred %2 ms, hard limit %3 ms); "
                "requesting a fresh keyframe")
            .arg(static_cast<qulonglong>(
                decision.bufferedDurationNanoseconds / 1'000'000
            ))
            .arg(static_cast<qulonglong>(
                preferredBufferedVideoNanoseconds / 1'000'000
            ))
            .arg(static_cast<qulonglong>(
                kMaximumBufferedVideoNanoseconds / 1'000'000
            ))
    );
    writeInputEvent(
        socket,
        InputEvent(
            InputEventType::Command,
            0,
            0,
            kIDRRequestKeyCode
        )
    );
}

void NetworkListener::processTcpBuffer(QTcpSocket* socket) {
    QByteArray& buffer = m_tcpBuffers[socket];
    catchUpStaleTcpVideo(socket, buffer);
    int consumed = 0;
    int processedPackets = 0;

    // Length-prefixed framing: [uint32_be length][body]
    while (buffer.size() - consumed >= 4
           && processedPackets < kMaxTcpPacketsPerDrain) {
        uint32_t length = qFromBigEndian<uint32_t>(
            reinterpret_cast<const uchar*>(buffer.constData() + consumed));

        // Sanity check: single frame should never exceed 8MB
        if (length > kMaxPacketSize) {
            qWarning() << "TCP framing error: packet length" << length
                        << "exceeds max" << kMaxPacketSize << "— resetting buffer";
            buffer.clear();
            consumed = 0;
            return;
        }

        int totalNeeded = 4 + static_cast<int>(length);
        if (buffer.size() - consumed < totalNeeded) {
            break; // Wait for more data
        }

        QByteArray body = buffer.mid(consumed + 4, static_cast<int>(length));
        consumed += totalNeeded;
        processedPackets++;

        // Every media connection must start with a typed identity message.
        const uint8_t typeByte =
            body.isEmpty() ? 0 : static_cast<uint8_t>(body[0]);
        if (!m_identifiedConnections.contains(socket)) {
            if (typeByte != 0x03 || body.size() <= 1) {
                rejectUnidentifiedConnection(
                    socket,
                    "first protocol message was not sender identity"
                );
                return;
            }
            m_identifiedConnections.insert(socket);
        }

        if (body.size() > 1) {
            if (typeByte == 0x03) {
                if (!handleIdentity(socket, body.mid(1))) {
                    return;
                }
            } else if (typeByte == 0x01) {
                // The video payload carries its stream identity, sequence,
                // timestamp and keyframe flag before the AVCC NALUs.
                handleVideoData(socket, body.mid(1));
            } else if (typeByte == 0x02) {
                handleAudioData(socket, body.mid(1));
            }
        }
    }

    // Remove all consumed bytes at once (avoids repeated O(n) shifts)
    if (consumed > 0) {
        buffer.remove(0, consumed);
    }

    // Video decode is synchronous on the Qt GUI thread. Bound each drain so
    // heartbeat and mDNS timers get a chance to run even when frames arrive
    // faster than they can be decoded.
    if (buffer.size() >= 4) {
        const uint32_t nextLength = qFromBigEndian<uint32_t>(
            reinterpret_cast<const uchar*>(buffer.constData())
        );
        if (nextLength <= kMaxPacketSize
            && buffer.size() >= 4 + static_cast<int>(nextLength)) {
            const QPointer<QTcpSocket> guardedSocket(socket);
            QTimer::singleShot(0, this, [this, guardedSocket]() {
                if (guardedSocket && m_tcpBuffers.contains(guardedSocket)) {
                    processTcpBuffer(guardedSocket);
                }
            });
        }
    }
}

bool NetworkListener::handleIdentity(
    QTcpSocket* socket,
    const QByteArray& payload
) {
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(payload, &parseError);
    const QJsonObject identity = document.object();
    const QString deviceId = identity.value("deviceId").toString().trimmed();
    const QString deviceName = identity.value("deviceName").toString().trimmed();
    const int protocolVersion = identity.value("protocolVersion").toInt();
    const QString connectionId = connectionIdFor(socket);

    if (parseError.error != QJsonParseError::NoError
        || !document.isObject()
        || protocolVersion != 1
        || deviceId.isEmpty()
        || deviceName.isEmpty()
        || deviceId.size() > 128
        || deviceName.size() > 128
        || connectionId.isEmpty()) {
        rejectUnidentifiedConnection(socket, "invalid sender identity");
        return false;
    }

    const auto existing = m_inboundSessions.sessionForConnection(
        connectionId.toStdString()
    );
    if (existing.has_value()) {
        if (existing->deviceId != deviceId.toStdString()) {
            rejectUnidentifiedConnection(
                socket,
                "sender identity changed on an active connection"
            );
            return false;
        }
        return true;
    }

    const auto result = m_inboundSessions.identify(
        connectionId.toStdString(),
        deviceId.toStdString(),
        deviceName.toStdString()
    );
    if (!result.has_value()) {
        rejectUnidentifiedConnection(socket, "identity could not be registered");
        return false;
    }

    if (result->replacedConnectionId.has_value()) {
        const QString replacedId =
            QString::fromStdString(*result->replacedConnectionId);
        if (auto* replacedSocket = m_socketsByConnectionId.value(replacedId)) {
            LogManager::instance().log(
                QString("Receiver: %1 moved to a new connection; replacing %2")
                    .arg(deviceName, replacedId)
            );
            replacedSocket->abort();
        }
    }

    const QString peerAddress = socket->peerAddress().toString();
    const quint16 peerPort = socket->peerPort();
    const QString connectionMode = connectionModeFor(socket);
    LogManager::instance().log(
        QString("Receiver: Identified %1 (%2) from %3:%4 via %5 "
                "[connection %6]")
            .arg(deviceName)
            .arg(deviceId)
            .arg(peerAddress)
            .arg(peerPort)
            .arg(connectionMode)
            .arg(connectionId)
    );
    emit connectionEstablished(
        deviceId,
        deviceName,
        connectionId,
        peerAddress,
        peerPort,
        connectionMode
    );
    emit statusChanged(
        QString("Connected to %1 sender(s)")
            .arg(static_cast<qulonglong>(
                m_inboundSessions.activeSessionCount()
            ))
    );
    return true;
}

void NetworkListener::rejectUnidentifiedConnection(
    QTcpSocket* socket,
    const QString& reason
) {
    LogManager::instance().log(
        QString("Receiver: Ignoring unidentified TCP connection from %1 — %2")
            .arg(
                socket
                    ? socket->peerAddress().toString()
                    : QStringLiteral("unknown")
            )
            .arg(reason)
    );
    if (socket) {
        socket->abort();
    }
}

void NetworkListener::handleVideoData(
    QTcpSocket* socket,
    const QByteArray& data
) {
    const auto binding = m_inboundSessions.sessionForConnection(
        connectionIdFor(socket).toStdString()
    );
    if (!binding.has_value()) {
        rejectUnidentifiedConnection(socket, "video arrived before sender identity");
        return;
    }

    video_packet::Header frameHeader;
    if (!video_packet::parseHeader(
            reinterpret_cast<const std::uint8_t*>(data.constData()),
            static_cast<std::size_t>(data.size()),
            frameHeader
        )) {
        LogManager::instance().log(
            "Receiver: Ignoring malformed video frame header"
        );
        return;
    }

    const qint64 receiverNow = m_videoTimelineClock.nsecsElapsed();
    const QString deviceId =
        QString::fromStdString(binding->deviceId);

    const bool resumingAfterRemoteKeyframe =
        m_waitingForVideoKeyframe.contains(socket);
    if (resumingAfterRemoteKeyframe) {
        if (!frameHeader.isKeyframe) {
            return;
        }
        m_waitingForVideoKeyframe.remove(socket);
    }

    if (!m_videoTimelines.contains(socket) || resumingAfterRemoteKeyframe) {
        // Fresh anchor after connect or remote-IDR recovery. Without this,
        // live delay stays > hard limit and catch-up discards the IDR again.
        m_videoTimelines[socket] = VideoTimeline{
            frameHeader.streamId,
            frameHeader.presentationTimestampNanoseconds,
            receiverNow,
        };
    } else {
        VideoTimeline& timeline = m_videoTimelines[socket];
        const std::uint64_t expectedPts =
            timeline.anchorPts
            + static_cast<std::uint64_t>(
                receiverNow - timeline.anchorReceiverNanoseconds
            );
        if (frameHeader.streamId != timeline.streamId) {
            timeline = VideoTimeline{
                frameHeader.streamId,
                frameHeader.presentationTimestampNanoseconds,
                receiverNow,
            };
            emit videoStreamResetRequired(deviceId);
        } else {
            if (frameHeader.presentationTimestampNanoseconds
                > expectedPts + kMaximumBufferedVideoNanoseconds) {
                timeline.anchorPts =
                    frameHeader.presentationTimestampNanoseconds;
                timeline.anchorReceiverNanoseconds = receiverNow;
            }
        }
    }

    static int frameCount = 0;
    frameCount++;
    if (frameCount <= 5 || frameCount % 300 == 0) {
        // Log first few bytes for debugging framing issues
        QString hexPreview;
        int previewLen = qMin(data.size(), 16);
        for (int i = 0; i < previewLen; i++) {
            hexPreview += QString("%1 ").arg(static_cast<uint8_t>(data[i]), 2, 16, QChar('0'));
        }
        LogManager::instance().log(
            QString("Video: frame %1, %2 bytes, stream=%3, sequence=%4 [%5]")
                .arg(frameCount)
                .arg(data.size())
                .arg(static_cast<qulonglong>(frameHeader.streamId))
                .arg(static_cast<qulonglong>(frameHeader.sequence))
                .arg(hexPreview.trimmed())
        );
    }
    emit videoDataReceived(
        deviceId,
        data
    );
}

void NetworkListener::handleAudioData(
    QTcpSocket* socket,
    const QByteArray& data
) {
    const auto binding = m_inboundSessions.sessionForConnection(
        connectionIdFor(socket).toStdString()
    );
    if (!binding.has_value()) {
        rejectUnidentifiedConnection(socket, "audio arrived before sender identity");
        return;
    }

    static int audioCount = 0;
    audioCount++;
    if (audioCount <= 3 || audioCount % 200 == 0) {
        qDebug() << "NetworkListener: Received audio data" << data.size() << "bytes (packet" << audioCount << ")";
    }
    emit audioDataReceived(
        QString::fromStdString(binding->deviceId),
        data
    );
}

void NetworkListener::onTcpDisconnected() {
    auto* socket = qobject_cast<QTcpSocket*>(sender());
    if (!socket) return;

    qDebug() << "TCP client disconnected:" << socket->peerAddress().toString();
    const QString connectionId = connectionIdFor(socket);
    const InboundCloseResult closed =
        m_inboundSessions.close(connectionId.toStdString());
    m_clients.removeAll(socket);
    m_tcpBuffers.remove(socket);
    m_identifiedConnections.remove(socket);
    m_connectionIds.remove(socket);
    m_connectionRoutes.remove(socket);
    m_socketsByConnectionId.remove(connectionId);
    m_lastTcpCatchUpCheck.remove(socket);
    m_lastTcpKeyframeRequest.remove(socket);
    m_waitingForVideoKeyframe.remove(socket);
    m_videoTimelines.remove(socket);
    socket->deleteLater();

    if (!closed.wasActive) {
        LogManager::instance().log(
            "Receiver: Unidentified/probe connection closed without affecting a window"
        );
        return;
    }

    emit connectionLost(QString::fromStdString(closed.deviceId));
    if (m_inboundSessions.activeSessionCount() == 0) {
        emit statusChanged("Waiting for connection...");
    } else {
        emit statusChanged(
            QString("Connected to %1 sender(s)")
                .arg(static_cast<qulonglong>(
                    m_inboundSessions.activeSessionCount()
                ))
        );
    }
}

void NetworkListener::onUdpReadyRead() {
    while (m_udpSocket->hasPendingDatagrams()) {
        QByteArray datagram;
        datagram.resize(static_cast<int>(m_udpSocket->pendingDatagramSize()));
        m_udpSocket->readDatagram(datagram.data(), datagram.size());

        if (!datagram.isEmpty()) {
            handleUdpPacket(datagram);
        }
    }
}

void NetworkListener::handleUdpPacket(const QByteArray& data) {
    if (data.size() <= 8) return;

    const uchar* raw = reinterpret_cast<const uchar*>(data.constData());
    uint32_t frameId = qFromBigEndian<uint32_t>(raw);
    uint16_t chunkId = qFromBigEndian<uint16_t>(raw + 4);
    uint16_t totalChunks = qFromBigEndian<uint16_t>(raw + 6);

    QByteArray payload = data.mid(8);

    QMutexLocker lock(&m_udpMutex);

    if (m_lastDecodedFrameId == 0) {
        m_lastDecodedFrameId = frameId - 1;
    }

    m_udpPacketsReceived++;

    // Stats logging every 3 seconds
    auto now = QDateTime::currentDateTime();
    if (m_lastStatsTime.msecsTo(now) > 3000) {
        qDebug() << "UDP Stats (3s): Pkts:" << m_udpPacketsReceived
                 << "Frames:" << m_udpFramesReassembled;
        m_udpPacketsReceived = 0;
        m_udpFramesReassembled = 0;
        m_lastStatsTime = now;
    }

    if (!m_udpBuffer.contains(frameId)) {
        UdpFrameEntry entry;
        entry.totalChunks = totalChunks;
        entry.timestamp = now;
        m_udpBuffer[frameId] = entry;
    }

    m_udpBuffer[frameId].chunks[chunkId] = payload;

    if (m_udpBuffer[frameId].chunks.size() == m_udpBuffer[frameId].totalChunks) {
        m_udpFramesReassembled++;

        // Gap detection — request IDR if frames were skipped
        int diff = static_cast<int>(frameId) - static_cast<int>(m_lastDecodedFrameId);
        if (diff > 1 && diff < 1000) {
            if (m_lastKeyframeRequest.msecsTo(now) > 2000) {
                qDebug() << "Frame gap detected" << m_lastDecodedFrameId << "->" << frameId << "requesting IDR";
                const InputEvent request(
                    InputEventType::Command,
                    0,
                    0,
                    kIDRRequestKeyCode
                );
                for (auto* client : m_clients) {
                    if (m_inboundSessions.sessionForConnection(
                            connectionIdFor(client).toStdString()
                        ).has_value()) {
                        writeInputEvent(client, request);
                    }
                }
                m_lastKeyframeRequest = now;
            }
        }
        m_lastDecodedFrameId = frameId;

        m_udpBuffer.remove(frameId);

        // Unlock before decode (decode may be slow)
        lock.unlock();
        static bool loggedMissingUdpIdentity = false;
        if (!loggedMissingUdpIdentity) {
            LogManager::instance().log(
                "Receiver: UDP media ignored because it has no sender identity"
            );
            loggedMissingUdpIdentity = true;
        }
        return;
    }

    // Periodic cleanup of stale incomplete frames
    if (m_udpPacketsReceived % 100 == 0) {
        QList<uint32_t> staleKeys;
        for (auto it = m_udpBuffer.begin(); it != m_udpBuffer.end(); ++it) {
            if (it->timestamp.msecsTo(now) > 1000) {
                staleKeys.append(it.key());
            }
        }
        for (uint32_t key : staleKeys) {
            m_udpBuffer.remove(key);
        }
    }
}

void NetworkListener::onHeartbeatTick() {
    InputEvent heartbeat(InputEventType::Command, 0, 0, kHeartbeatKeyCode);
    QByteArray packet = heartbeat.toPacket();

    for (auto* client : m_clients) {
        if (m_inboundSessions.sessionForConnection(
                connectionIdFor(client).toStdString()
            ).has_value()) {
            client->write(packet);
        }
    }
}

void NetworkListener::writeInputEvent(
    QTcpSocket* socket,
    const InputEvent& event
) {
    if (!socket) {
        return;
    }
    bool isCritical = (event.type == InputEventType::LeftMouseDown ||
                       event.type == InputEventType::LeftMouseUp ||
                       event.type == InputEventType::RightMouseDown ||
                       event.type == InputEventType::RightMouseUp ||
                       event.type == InputEventType::KeyDown ||
                       event.type == InputEventType::KeyUp ||
                       event.type == InputEventType::Command);

    int repeatCount = isCritical ? 3 : 1;
    QByteArray packet = event.toPacket();

    for (int i = 0; i < repeatCount; i++) {
        socket->write(packet);
    }
}

void NetworkListener::sendInputEvent(
    const QString& deviceId,
    const InputEvent& event
) {
    const auto binding =
        m_inboundSessions.sessionForDevice(deviceId.toStdString());
    if (!binding.has_value()) {
        return;
    }
    if (auto* socket = m_socketsByConnectionId.value(
            QString::fromStdString(binding->connectionId)
        )) {
        writeInputEvent(socket, event);
    }
}
