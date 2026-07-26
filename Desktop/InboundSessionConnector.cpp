#include "InboundSessionConnector.h"

#include <QAbstractSocket>
#include <QTcpSocket>

InboundSessionConnector::InboundSessionConnector(QObject* parent)
    : QObject(parent)
{
}

void InboundSessionConnector::connectExplicit(
    const InboundCompatibilityEndpoint& endpoint
) {
    auto* socket = new QTcpSocket(this);
    socket->setSocketOption(QAbstractSocket::LowDelayOption, 1);
    socket->setSocketOption(QAbstractSocket::KeepAliveOption, 1);

    connect(socket, &QTcpSocket::connected, this, [this, socket]() {
        emit connectionReady(socket);
        if (socket->parent() == this) {
            emit statusChanged(
                "Compatibility connection could not be adopted."
            );
            socket->deleteLater();
            return;
        }
        socket->disconnect(this);
    });
    connect(
        socket,
        &QTcpSocket::errorOccurred,
        this,
        [this, socket](QAbstractSocket::SocketError) {
            emit statusChanged(
                "Compatibility connection failed: "
                + socket->errorString()
            );
            socket->deleteLater();
        }
    );

    const QString host = QString::fromStdString(endpoint.host);
    emit statusChanged(
        QString("Starting explicit compatibility connection to %1:%2...")
            .arg(host)
            .arg(endpoint.port)
    );
    socket->connectToHost(host, endpoint.port);
}
