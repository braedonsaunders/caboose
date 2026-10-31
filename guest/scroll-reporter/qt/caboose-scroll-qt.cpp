// The Qt Quick scroll reporter (docs/display.md, "Scroll reports"). The preload library
// libcaboose-scroll-qt6.so (loader.c) loads it into processes that have Qt Quick.
//
// Its constructor registers a Qt pre-routine, which runs once the application object
// exists. For every QQuickWindow it then reads, on the GUI thread after animations advance
// and before the scene graph synchronizes (afterAnimating), every Flickable's contentX,
// contentY, content size and scene rectangle, through properties only. It reports the
// largest Flickable first and every other one after it. Each frame whose report changed
// redraws the frame tag, an item of its own on top of the window's content, placed in the
// bottom overscan. The tag is drawn in that same frame's scene graph, so the picture names
// its report. scroll.target deltas move contentX/contentY, and the frame that draws the
// result reports their seq as applied.
#include <QtCore/QCoreApplication>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QPointer>
#include <QtCore/QSocketNotifier>
#include <QtCore/QTimer>
#include <QtGui/QGuiApplication>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>
#include <QtQuick/QSGSimpleRectNode>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

constexpr int Blocks = 32;

bool tagBit(quint32 value, int i) {
    if (i < 4) return i % 2 == 0;
    if (i < 28) return (value >> (27 - i)) & 1;
    quint32 check = 0;
    for (int k = 0; k < 6; k++) check ^= (value >> (4 * k)) & 0xf;
    return (check >> (31 - i)) & 1;
}

/** The frame tag: 32 black or white squares, drawn by the scene graph. */
class Tag : public QQuickItem {
public:
    explicit Tag(QQuickItem *parent) : QQuickItem(parent) { setFlag(ItemHasContents); }
    void show(quint32 value) {
        m_value = value;
        update();
    }

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override {
        QSGNode *root = old ? old : new QSGNode;
        while (root->childCount() < Blocks) root->appendChildNode(new QSGSimpleRectNode);
        const qreal side = height();
        int i = 0;
        for (QSGNode *n = root->firstChild(); n; n = n->nextSibling(), i++) {
            auto *rect = static_cast<QSGSimpleRectNode *>(n);
            rect->setRect(i * side, 0, side, side);
            rect->setColor(tagBit(m_value, i) ? Qt::white : Qt::black);
        }
        return root;
    }

private:
    quint32 m_value = 0;
};

struct Bind {
    bool bound = false, active = false;
    int reporter = 0;
    double overscanH = 0, tagTop = 0, block = 0;
};

class Reporter : public QObject {
public:
    Reporter() {
        connectSocket();
        auto *poll = new QTimer(this);
        connect(poll, &QTimer::timeout, this, &Reporter::pollWindows);
        poll->start(250);
    }

private:
    struct Win {
        QPointer<QQuickWindow> window;
        QPointer<Tag> tag;
        quint16 frame = 0;
        quint64 epoch = 0;
        double lastExtent = 0;
        QByteArray last;
    };

    int m_sock = -1;
    QSocketNotifier *m_notifier = nullptr;
    QByteArray m_in;
    Bind m_bind;
    quint64 m_applied = 0;
    QList<Win *> m_wins;
    Win *m_reporting = nullptr;
    QHash<QObject *, int> m_ids;
    int m_nextId = 1;

    void connectSocket() {
        const char *path = getenv("CABOOSE_SCROLL_SOCKET");
        if (!path || !*path) return;
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        if (fd < 0 || strlen(path) >= sizeof addr.sun_path) return;
        strcpy(addr.sun_path, path);
        if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) < 0) {
            close(fd);
            return;
        }
        m_sock = fd;
        m_in.clear();
        m_notifier = new QSocketNotifier(fd, QSocketNotifier::Read, this);
        connect(m_notifier, &QSocketNotifier::activated, this, &Reporter::readSocket);
    }

    void dropSocket() {
        if (m_notifier) m_notifier->deleteLater();
        m_notifier = nullptr;
        if (m_sock >= 0) close(m_sock);
        m_sock = -1;
        m_bind.bound = false;
    }

    void send(const QByteArray &json) {
        if (m_sock < 0) return;
        quint32 n = json.size();
        unsigned char head[4] = {quint8(n), quint8(n >> 8), quint8(n >> 16), quint8(n >> 24)};
        iovec iov[2] = {{head, 4}, {const_cast<char *>(json.constData()), size_t(n)}};
        msghdr m{};
        m.msg_iov = iov;
        m.msg_iovlen = 2;
        // A reporter that cannot keep up drops reports; a later one replaces them.
        if (sendmsg(m_sock, &m, MSG_DONTWAIT | MSG_NOSIGNAL) < 0 && errno != EAGAIN) dropSocket();
    }

    void readSocket() {
        char buf[65536];
        ssize_t n = read(m_sock, buf, sizeof buf);
        if (n <= 0) return dropSocket();
        m_in.append(buf, n);
        while (m_in.size() >= 4) {
            const auto *b = reinterpret_cast<const unsigned char *>(m_in.constData());
            quint32 len = b[0] | b[1] << 8 | b[2] << 16 | quint32(b[3]) << 24;
            if (len > (1u << 20)) return dropSocket();
            if (quint32(m_in.size()) < 4 + len) break;
            onMessage(QJsonDocument::fromJson(m_in.mid(4, len)).object());
            m_in.remove(0, 4 + len);
        }
    }

    void onMessage(const QJsonObject &m) {
        const QString type = m.value("type").toString();
        if (type == "bind") {
            const QJsonArray overscan = m.value("overscan").toArray();
            m_bind = {true, m.value("active").toBool(), m.value("reporter").toInt(), overscan.at(1).toDouble(),
                      m.value("tag_top").toDouble(), m.value("block").toDouble()};
        } else if (type == "unbind") {
            m_bind.bound = false;
        } else if (type == "target") {
            applyTarget(m);
        } else {
            return;
        }
        for (Win *w : m_wins) w->last.clear();
        if (m_reporting && m_reporting->window) m_reporting->window->update();
    }

    struct Found {
        QQuickItem *item;
        QRectF rect; // window logical pixels
    };

    static void collect(QQuickItem *item, QList<Found> &out, const Tag *skip) {
        for (QQuickItem *child : item->childItems()) {
            if (child == skip || !child->isVisible()) continue;
            if (child->inherits("QQuickFlickable")) out.append({child, child->mapRectToScene(child->boundingRect())});
            collect(child, out, skip);
        }
    }

    QList<Found> scrollers(Win *w) {
        QList<Found> found;
        collect(w->window->contentItem(), found, w->tag);
        std::stable_sort(found.begin(), found.end(), [](const Found &a, const Found &b) {
            return a.rect.width() * a.rect.height() > b.rect.width() * b.rect.height();
        });
        if (found.size() > 8) found.resize(8);
        return found;
    }

    int idOf(QObject *o) {
        auto it = m_ids.find(o);
        if (it != m_ids.end()) return *it;
        connect(o, &QObject::destroyed, this, [this, o] { m_ids.remove(o); });
        return m_ids[o] = m_nextId++;
    }

    void applyTarget(const QJsonObject &m) {
        const quint64 seq = quint64(m.value("seq").toDouble());
        const int id = m.value("scroller").toInt();
        const QJsonArray delta = m.value("delta").toArray();
        if (m_reporting && m_reporting->window) {
            const double dpr = m_reporting->window->effectiveDevicePixelRatio();
            for (const Found &f : scrollers(m_reporting)) {
                if (idOf(f.item) != id) continue;
                const double dx = delta.at(0).toDouble() / dpr, dy = delta.at(1).toDouble() / dpr;
                if (dx != 0) f.item->setProperty("contentX", f.item->property("contentX").toDouble() + dx);
                if (dy != 0) f.item->setProperty("contentY", f.item->property("contentY").toDouble() + dy);
            }
        }
        m_applied = qMax(m_applied, seq);
    }

    void pollWindows() {
        for (QWindow *window : QGuiApplication::topLevelWindows()) {
            auto *quick = qobject_cast<QQuickWindow *>(window);
            if (!quick || !quick->isVisible()) continue;
            if (std::any_of(m_wins.begin(), m_wins.end(), [&](Win *w) { return w->window == quick; })) continue;
            auto *w = new Win;
            w->window = quick;
            w->tag = new Tag(quick->contentItem());
            w->tag->setZ(1e9);
            w->tag->setVisible(false);
            m_wins.append(w);
            connect(quick, &QQuickWindow::afterAnimating, this, [this, w] { frame(w); });
            quick->update();
        }
        if (m_sock < 0 && !m_wins.isEmpty()) connectSocket();
    }

    static QJsonArray rect(const QRectF &r, double dpr) {
        return {r.x() * dpr, r.y() * dpr, r.width() * dpr, r.height() * dpr};
    }

    /** Before the scene graph takes this frame: report it, and draw its tag if it changed. */
    void frame(Win *w) {
        if (m_sock < 0 || !w->window) return;
        QQuickWindow *window = w->window;
        const double dpr = window->effectiveDevicePixelRatio();
        const QList<Found> found = scrollers(w);
        if (found.isEmpty()) return;
        const QSizeF size = window->contentItem()->size();
        bool tagged = false;
        double side = 0, top = 0;
        if (m_bind.bound && m_bind.active && (m_reporting == w || !m_reporting)) {
            side = std::ceil(m_bind.block / dpr - 1e-6);
            top = std::round(m_bind.tagTop / dpr);
            tagged = side > 0 && m_bind.overscanH >= side * dpr && top >= 0 && top + side <= size.height();
        }
        const double extent = found[0].item->property("contentHeight").toDouble();
        // Content that grows or shrinks around the offset moves in document coordinates.
        if (w->lastExtent != 0 && extent != w->lastExtent) w->epoch++;
        w->lastExtent = extent;
        QJsonArray list;
        for (int i = 0; i < found.size(); i++) {
            QQuickItem *f = found[i].item;
            const double cx = f->property("contentX").toDouble() - f->property("originX").toDouble();
            const double cy = f->property("contentY").toDouble() - f->property("originY").toDouble();
            const double rx = qMax(0.0, f->property("contentWidth").toDouble() - f->width());
            const double ry = qMax(0.0, f->property("contentHeight").toDouble() - f->height());
            QJsonObject s{{"id", idOf(f)}, {"rect", rect(found[i].rect, dpr)}, {"offset", QJsonArray{cx * dpr, cy * dpr}},
                          {"range", QJsonArray{rx * dpr, ry * dpr}}};
            if (i == 0 && tagged) s["fixed"] = QJsonArray{rect(QRectF(0, top, Blocks * side, side), dpr)};
            list.append(s);
        }
        QJsonObject report{{"type", "report"},
                           {"title", window->title()},
                           {"outer", QJsonArray{size.width() * dpr, size.height() * dpr}},
                           {"viewport", QJsonArray{size.width() * dpr, size.height() * dpr}},
                           {"applied", double(m_applied)},
                           {"epoch", double(w->epoch)},
                           {"tag", tagged ? QJsonValue(rect(QRectF(0, top, Blocks * side, side), dpr)) : QJsonValue()},
                           {"scrollers", list}};
        const QByteArray key = QJsonDocument(report).toJson(QJsonDocument::Compact);
        if (key == w->last) return;
        w->last = key;
        w->frame++;
        report["frame"] = int(w->frame);
        m_reporting = w;
        send(QJsonDocument(report).toJson(QJsonDocument::Compact));
        w->tag->setVisible(tagged);
        if (tagged) {
            w->tag->setPosition(QPointF(0, top));
            w->tag->setSize(QSizeF(Blocks * side, side));
            w->tag->show(quint32(m_bind.reporter & 0xff) << 16 | w->frame);
        }
    }
};

void start() {
    // A plain QCoreApplication has no windows to report.
    if (!qobject_cast<QGuiApplication *>(QCoreApplication::instance())) return;
    QTimer::singleShot(0, [] { new Reporter; });
}

__attribute__((constructor)) void preload() { qAddPreRoutine(start); }

} // namespace
