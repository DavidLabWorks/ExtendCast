#pragma once

#include <QObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUdpSocket>
#include <QTimer>
#include <QMutex>
#include <QHash>
#include <QByteArray>
#include <QDateTime>
#include <QString>

#include "InputEvent.h"
#include "InboundSessionRegistry.h"

class NetworkListener : public QObject {
    Q_OBJECT

public:
    explicit NetworkListener(QObject* parent = nullptr);
    ~NetworkListener();

    void start();
    void stop();
    bool isListening() const;
    void adoptConnectedRemoteSender(QTcpSocket* socket);
    void disconnectAll();
    const QList<QTcpSocket*>& clients() const { return m_clients; }
    uint16_t actualTcpPort() const;

signals:
    void connectionEstablished(
        const QString& deviceId,
        const QString& deviceName,
        const QString& connectionId,
        const QString& peerAddress
    );
    void connectionLost(const QString& deviceId);
    void videoDataReceived(
        const QString& deviceId,
        const QByteArray& data,
        bool hasPtsPrefix
    );
    void audioDataReceived(
        const QString& deviceId,
        const QByteArray& data
    );
    void statusChanged(const QString& status);

public slots:
    void sendInputEvent(const QString& deviceId, const InputEvent& event);

private slots:
    void onNewTcpConnection();
    void onTcpReadyRead();
    void onTcpDisconnected();
    void onUdpReadyRead();
    void onHeartbeatTick();

private:
    void adoptInboundSocket(
        QTcpSocket* socket,
        const QString& logDescription
    );
    void processTcpBuffer(QTcpSocket* socket);
    bool handleIdentity(QTcpSocket* socket, const QByteArray& payload);
    void handleVideoData(
        QTcpSocket* socket,
        const QByteArray& data,
        bool hasPtsPrefix = true
    );
    void handleAudioData(QTcpSocket* socket, const QByteArray& data);
    void handleUdpPacket(const QByteArray& data);
    QString connectionIdFor(QTcpSocket* socket) const;
    void registerSocket(QTcpSocket* socket);
    void rejectUnidentifiedConnection(QTcpSocket* socket, const QString& reason);
    void writeInputEvent(QTcpSocket* socket, const InputEvent& event);

    // TCP
    QTcpServer* m_tcpServer = nullptr;
    QList<QTcpSocket*> m_clients;
    QHash<QTcpSocket*, QByteArray> m_tcpBuffers;
    QHash<QTcpSocket*, QString> m_connectionIds;
    QHash<QString, QTcpSocket*> m_socketsByConnectionId;
    InboundSessionRegistry m_inboundSessions;

    // Per-connection admission state: -1 = waiting for identity,
    // 1 = typed framing with an admitted sender identity.
    QHash<QTcpSocket*, int> m_connectionFormat;

    // UDP
    QUdpSocket* m_udpSocket = nullptr;
    static constexpr uint16_t kDefaultTcpPort = 51820;
    static constexpr uint16_t kDefaultUdpPort = 51821;
    static constexpr uint32_t kMaxPacketSize = 8 * 1024 * 1024;   // 8MB per frame max
    static constexpr int kMaxBufferSize = 32 * 1024 * 1024;       // 32MB buffer limit

    // UDP reassembly
    struct UdpFrameEntry {
        int totalChunks = 0;
        QHash<uint16_t, QByteArray> chunks;
        QDateTime timestamp;
    };
    QHash<uint32_t, UdpFrameEntry> m_udpBuffer;
    QMutex m_udpMutex;
    uint32_t m_lastDecodedFrameId = 0;
    QDateTime m_lastKeyframeRequest;

    // Heartbeat
    QTimer* m_heartbeatTimer = nullptr;

    // Stats
    int m_udpPacketsReceived = 0;
    int m_udpFramesReassembled = 0;
    QDateTime m_lastStatsTime;
};
