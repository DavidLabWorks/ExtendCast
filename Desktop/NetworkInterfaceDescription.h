#pragma once

#include <QNetworkInterface>
#include <QString>

QString detailedNetworkInterfaceDescription(
    const QNetworkInterface& networkInterface
);
