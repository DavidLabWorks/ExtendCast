#pragma once

#include <QApplication>
#include <QColor>
#include <QIcon>
#include <QPainter>
#include <QPixmap>

namespace UiIcons {

inline QPixmap fullscreenCornersPixmap(const QColor& color) {
    constexpr int size = 16;
    const qreal dpr = qApp ? qApp->devicePixelRatio() : 1.0;
    QPixmap pixmap(
        qRound(size * dpr),
        qRound(size * dpr)
    );
    pixmap.setDevicePixelRatio(dpr);
    pixmap.fill(Qt::transparent);

    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing);
    QPen pen(color, 1.6, Qt::SolidLine, Qt::SquareCap, Qt::MiterJoin);
    painter.setPen(pen);

    painter.drawLine(QPointF(2.5, 6.0), QPointF(2.5, 2.5));
    painter.drawLine(QPointF(2.5, 2.5), QPointF(6.0, 2.5));
    painter.drawLine(QPointF(10.0, 2.5), QPointF(13.5, 2.5));
    painter.drawLine(QPointF(13.5, 2.5), QPointF(13.5, 6.0));
    painter.drawLine(QPointF(2.5, 10.0), QPointF(2.5, 13.5));
    painter.drawLine(QPointF(2.5, 13.5), QPointF(6.0, 13.5));
    painter.drawLine(QPointF(10.0, 13.5), QPointF(13.5, 13.5));
    painter.drawLine(QPointF(13.5, 13.5), QPointF(13.5, 10.0));
    return pixmap;
}

inline QIcon fullscreenCorners() {
    QIcon icon;
    icon.addPixmap(
        fullscreenCornersPixmap(QColor("#d8d8d8")),
        QIcon::Normal
    );
    icon.addPixmap(
        fullscreenCornersPixmap(QColor("#ffffff")),
        QIcon::Active
    );
    return icon;
}

inline QPixmap exitFullscreenCornersPixmap(const QColor& color) {
    constexpr int size = 16;
    const qreal dpr = qApp ? qApp->devicePixelRatio() : 1.0;
    QPixmap pixmap(
        qRound(size * dpr),
        qRound(size * dpr)
    );
    pixmap.setDevicePixelRatio(dpr);
    pixmap.fill(Qt::transparent);

    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing);
    QPen pen(color, 1.6, Qt::SolidLine, Qt::SquareCap, Qt::MiterJoin);
    painter.setPen(pen);

    // Four corners point inward to communicate leaving fullscreen.
    painter.drawLine(QPointF(2.5, 6.0), QPointF(6.0, 6.0));
    painter.drawLine(QPointF(6.0, 6.0), QPointF(6.0, 2.5));
    painter.drawLine(QPointF(10.0, 2.5), QPointF(10.0, 6.0));
    painter.drawLine(QPointF(10.0, 6.0), QPointF(13.5, 6.0));
    painter.drawLine(QPointF(2.5, 10.0), QPointF(6.0, 10.0));
    painter.drawLine(QPointF(6.0, 10.0), QPointF(6.0, 13.5));
    painter.drawLine(QPointF(10.0, 13.5), QPointF(10.0, 10.0));
    painter.drawLine(QPointF(10.0, 10.0), QPointF(13.5, 10.0));
    return pixmap;
}

inline QIcon exitFullscreenCorners() {
    QIcon icon;
    icon.addPixmap(
        exitFullscreenCornersPixmap(QColor("#d8d8d8")),
        QIcon::Normal
    );
    icon.addPixmap(
        exitFullscreenCornersPixmap(QColor("#ffffff")),
        QIcon::Active
    );
    return icon;
}

inline QPixmap disconnectCirclePixmap(const QColor& background) {
    constexpr int size = 16;
    const qreal dpr = qApp ? qApp->devicePixelRatio() : 1.0;
    QPixmap pixmap(
        qRound(size * dpr),
        qRound(size * dpr)
    );
    pixmap.setDevicePixelRatio(dpr);
    pixmap.fill(Qt::transparent);

    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setPen(Qt::NoPen);
    painter.setBrush(background);
    painter.drawEllipse(QRectF(1.0, 1.0, 14.0, 14.0));

    QPen closePen(
        QColor("#ffffff"),
        1.5,
        Qt::SolidLine,
        Qt::RoundCap
    );
    painter.setPen(closePen);
    painter.drawLine(QPointF(5.3, 5.3), QPointF(10.7, 10.7));
    painter.drawLine(QPointF(10.7, 5.3), QPointF(5.3, 10.7));
    return pixmap;
}

inline QIcon disconnectCircle() {
    QIcon icon;
    icon.addPixmap(
        disconnectCirclePixmap(QColor("#d13438")),
        QIcon::Normal
    );
    icon.addPixmap(
        disconnectCirclePixmap(QColor("#e5484d")),
        QIcon::Active
    );
    return icon;
}

} // namespace UiIcons
