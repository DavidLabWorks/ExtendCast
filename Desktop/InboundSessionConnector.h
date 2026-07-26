#pragma once

#include <QObject>
#include <QString>

#include "InboundCompatibilityEndpoint.h"

class QTcpSocket;

/// Dials a Remote Sender only for an explicit manual or ADB compatibility
/// action. Normal Receiver discovery never calls this module.
class InboundSessionConnector : public QObject {
    Q_OBJECT

public:
    explicit InboundSessionConnector(QObject* parent = nullptr);

    void connectExplicit(const InboundCompatibilityEndpoint& endpoint);

signals:
    void connectionReady(QTcpSocket* socket);
    void statusChanged(const QString& status);
};
