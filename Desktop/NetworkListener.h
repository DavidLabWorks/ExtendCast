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
#include <QElapsedTimer>
#include <QSet>
#include <QString>

#include <cstdint>

#include "InputEvent.h"
#include "InboundSessionRegistry.h"
#include "ReceiverRouteClassifier.h"

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
        const QString& peerAddress,
        quint16 peerPort,
        const QString& connectionMode
    );
    void connectionLost(const QString& deviceId);
    void videoDataReceived(
        const QString& deviceId,
        const QByteArray& data
    );
    void audioDataReceived(
        const QString& deviceId,
        const QByteArray& data
    );
    void videoStreamResetRequired(const QString& deviceId);
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
    void catchUpStaleTcpVideo(
        QTcpSocket* socket,
        QByteArray& buffer
    );
    void processTcpBuffer(QTcpSocket* socket);
    bool handleIdentity(QTcpSocket* socket, const QByteArray& payload);
    void handleVideoData(
        QTcpSocket* socket,
        const QByteArray& data
    );
    void handleAudioData(QTcpSocket* socket, const QByteArray& data);
    void handleUdpPacket(const QByteArray& data);
    QString connectionIdFor(QTcpSocket* socket) const;
    ReceiverAdvertisedRoute connectionRouteFor(QTcpSocket* socket) const;
    QString connectionModeFor(QTcpSocket* socket) const;
    void registerSocket(QTcpSocket* socket);
    void rejectUnidentifiedConnection(QTcpSocket* socket, const QString& reason);
    void writeInputEvent(QTcpSocket* socket, const InputEvent& event);

    // TCP
    QTcpServer* m_tcpServer = nullptr;
    QList<QTcpSocket*> m_clients;
    QHash<QTcpSocket*, QByteArray> m_tcpBuffers;
    QHash<QTcpSocket*, QString> m_connectionIds;
    QHash<QTcpSocket*, ReceiverAdvertisedRoute> m_connectionRoutes;
    QHash<QString, QTcpSocket*> m_socketsByConnectionId;
    InboundSessionRegistry m_inboundSessions;

    // A media connection is admitted only after its first typed identity
    // message has been validated.
    QSet<QTcpSocket*> m_identifiedConnections;
    QHash<QTcpSocket*, QDateTime> m_lastTcpCatchUpCheck;
    QHash<QTcpSocket*, QDateTime> m_lastTcpKeyframeRequest;
    QSet<QTcpSocket*> m_waitingForVideoKeyframe;
    struct VideoTimeline {
        std::uint64_t streamId = 0;
        std::uint64_t anchorPts = 0;
        qint64 anchorReceiverNanoseconds = 0;
    };
    QHash<QTcpSocket*, VideoTimeline> m_videoTimelines;
    QElapsedTimer m_videoTimelineClock;

    // UDP
    QUdpSocket* m_udpSocket = nullptr;
    static constexpr uint16_t kDefaultTcpPort = 51820;
    static constexpr uint16_t kDefaultUdpPort = 51821;
    static constexpr uint32_t kMaxPacketSize = 8 * 1024 * 1024;   // 8MB per frame max
    static constexpr int kMaxBufferSize = 32 * 1024 * 1024;       // 32MB buffer limit
    static constexpr int kMaxTcpPacketsPerDrain = 4;
    static constexpr uint64_t kMaximumBufferedVideoNanoseconds =
        500'000'000;
    static constexpr int kTcpCatchUpCheckIntervalMs = 100;
    static constexpr int kTcpKeyframeRequestIntervalMs = 500;

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
