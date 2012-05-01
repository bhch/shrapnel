# Copyright (c) 2002-2011 IronPort Systems and Cisco Systems
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# -*- Mode: Pyrex -*-

# Note: this file is included by <coro.pyx>

__poller_version__ = "$Id"

# ================================================================================
#                                epoll
# ================================================================================

from libc cimport uint64_t, uint32_t
from libc cimport uint64_t

cdef extern from "sys/time.h":
    cdef struct timespec:
        unsigned int tv_sec
        unsigned int tv_nsec

cdef extern from "sys/epoll.h":
    ctypedef union epoll_data_t:
        void *ptr
        int fd
        uint32_t u32
        uint64_t u64

    cdef struct epoll_event:
        uint32_t events
        epoll_data_t data

    int epoll_create(int size)

    int epoll_ctl (
        int epfd,
        int op,
        int fd,
        epoll_event *event
        )

    int epoll_wait (
        int epfd,
        epoll_event *events,
        int maxevents,
        int timeout
        )

    int EPOLL_CTL_ADD, EPOLL_CTL_MOD, EPOLL_CTL_DEL
    int EPOLLHUP, EPOLLPRI, EPOLLERR, EPOLLET, EPOLLONESHOT, EPOLLRDHUP
    int EPOLLIN, EPOLLOUT

cdef struct shrapnel_epoll_event:
    uint32_t events
    epoll_data_t data
    int op
    int flags
    int err

cdef int SECS_TO_MILLISECS = 1000
cdef double NSECS_TO_MILLISECS = 1000000.0

class EV:

    """epoll flags."""

    ADD      = EPOLL_CTL_ADD        # add event to kq (implies enable)
    DELETE   = EPOLL_CTL_DEL     # delete event from kq
    ONESHOT  = EPOLLONESHOT    # only report one occurrence
    EOF      = EPOLLHUP        # EOF detected
    ERROR    = EPOLLERR      # error, data contains errno

class EFILT:

    """epoll event filters."""

    READ     = EPOLLIN   #
    WRITE    = EPOLLOUT  #

# Definition of epoll status flags:
# - NEW: Target is new, event not yet submitted.
# - SUBMITTED: The event has been submitted to epoll.
# - FIRED: The event has fired.
# - ABORTED: The event has been aborted (typically by Interrupted exception).
#            The event may or may not have already been submitted.
cdef enum:
    EVENT_STATUS_NEW
    EVENT_STATUS_SUBMITTED
    EVENT_STATUS_FIRED
    EVENT_STATUS_ABORTED

cdef class py_event:

    """Representation of a epoll event.

    :IVariables:
        - `events`: Epoll events
        - `data`: User data variable
    """

    cdef uint32_t events
    cdef epoll_data_t data
    cdef int flags
    cdef int err

    # cinit cannot take a C struct.
    # It would be nice to support fast-constructor semantics in Cython.
    cdef __fast_init__ (self, shrapnel_epoll_event *e):
        self.events = e.events
        self.data.fd = e.data.fd
        self.flags = e.flags
        self.err = e.err 

    def __repr__(self):
        return '<py_event events=%r>' % (self.events)

cdef class event_key:

    """event key.

    All epoll events are uniquely identified by a key which is a combination of the
    events and fd.

    :IVariables:
        - `events`: The event filter (see `EFILT`).
        - `data`: The data identifier (depends on the filter type, but is
          often a file descriptor).
    """

    cdef int events
    cdef int fd
    cdef int op

    def __cinit__ (self, int events, int fd, int op=EPOLL_CTL_MOD):
        self.events = events
        self.fd = fd
        self.op = op

    def __hash__ (self):
        cdef int value
        value = (self.fd << 4) | (self.events)
        if value == -1:
            value = -2
        return value

    def __repr__ (self):
        return '<event_key events=%d fd=%x>' % (self.events, self.fd)

    def __richcmp__ (event_key self, event_key other, int op):
        # all we need is EQ, ignore the rest
        if op != 2:
            raise ValueError, "event_key() only supports '==' rich comparison"
        else:
            return (self.events == other.events) and (self.fd == other.fd)

cdef public class queue_poller [ object queue_poller_object, type queue_poller_type ]:

    cdef int ep_fd
    cdef object event_map

    def __init__ (self):
        self.ep_fd = -1
        self.event_map = {}

    cdef set_up(self):
        self.ep_fd = epoll_create(1000)
        if self.ep_fd == -1:
            raise SystemError, "epoll_create() failed"

    cdef tear_down(self):
        if self.ep_fd != -1:
            libc.close(self.ep_fd)
            self.ep_fd = -1

    cdef object set_wait_for (self, event_key ek):
        cdef coro me
        cdef unsigned flag = 0
        if PyDict_Contains (self.event_map, ek):
            # Should be impossible to have KeyError due to previous line.
            et = self.event_map[ek]
            raise SimultaneousError (the_scheduler._current, et.target, ek)
        else:

            ek1 = event_key (EPOLLOUT, ek.fd)
            ek2 = event_key (EPOLLIN, ek.fd)

            if ( (PyDict_Contains (self.event_map, ek2) and ek.events == EPOLLOUT) or
                (PyDict_Contains (self.event_map, ek1) and ek.events == EPOLLIN)):
                flags = EPOLLOUT | EPOLLIN | EPOLLET
            else:
                flags = EPOLLET

            me = the_scheduler._current
            target = me
            self.event_map[ek] = target
            self._register_event(ek, flags)

            return target

    def set_handler (self, object event, object handler, int flags=0, unsigned int fflags=0):
        return

    cdef notify_of_close (self, int fd):
        return

    cdef _register_event(self, event_key ek, unsigned int flags): 
        cdef int r
        cdef epoll_event org_e
        org_e.data.fd = ek.fd
        org_e.events = ek.events | flags 

        r = epoll_ctl (
            self.ep_fd,
            EPOLL_CTL_MOD,
            org_e.data.fd,
            &org_e
        )

        # if fd doesn't exist in epoll, add it
        if r == -1 and (libc.errno == libc.ENOENT):
            r = epoll_ctl (
                self.ep_fd,
                EPOLL_CTL_ADD,
                org_e.data.fd,
                &org_e
            )

        if r == -1 and (libc.errno != libc.EEXIST):
            raise_oserror()

    cdef _wait_for_with_eof (self, int fd, int events):
        cdef py_event event
        event = self._wait_for (fd, events)
        if event.err:
            raise_oserror_with_errno(event.err)
        else:
            return 1024

    cdef _wait_for_read (self, int fd):
        return self._wait_for_with_eof(fd, EPOLLIN)

    cdef _wait_for_write (self, int fd):
        return self._wait_for_with_eof(fd, EPOLLOUT)

    cdef py_event _wait_for (self, int fd, int events):
        cdef event_key ek
        ek = event_key (events, fd)
        et = self.set_wait_for (ek)
        return _YIELD()

    def wait_for (self, int fd, int events):
        """Wait for an event.

        :Parameters:
            - `ident`: The event identifier (depends on the filter type, but
              is often a file descriptor).
            - `filter`: The event filter (see `EVFILT`).

        :Return:
            Returns a `py_event` instance that indicates the event that fired.

        :Exceptions:
            - `SimultaneousError`: Something is already waiting for this event.
        """
        return self._wait_for(fd, events)

    cdef delete_event (self, int fd, int events):
        cdef int r
        cdef epoll_event e
        e.data.fd = fd
        e.events = events | EPOLLONESHOT
        r = epoll_ctl (self.ep_fd, EPOLL_CTL_DEL, fd, &e)
        #if r < 0:
        #    raise_oserror()

    def poll (self, timeout=(30,0), int nevents=2000):
        cdef timespec ts
        cdef int r, i
        cdef epoll_event * events
        cdef shrapnel_epoll_event new_e
        cdef coro co
        cdef event_key ek
        cdef py_event _py_event
        ts.tv_sec, ts.tv_nsec = timeout
        events = <epoll_event *> libc.alloca (sizeof (epoll_event) * nevents)

        r = epoll_wait (self.ep_fd, events, nevents, timeout[0] * SECS_TO_MILLISECS + (timeout[1] / NSECS_TO_MILLISECS))
        #W ('{%d}' % (r,))
        #P('mapsize = %i' % len(self.event_map))
        for i from 0 <= i < r:
            new_e.data.fd = events[i].data.fd
            new_e.events = events[i].events
            new_e.err = 0
            #print 'epoll_wait event >>>>>> %s for %s' % (new_e.events, new_e.data.fd)
            tmp = (EPOLLIN, EPOLLOUT)
            if events[i].events & tmp[0] and events[i].events & tmp[1]:
                pass
            else:
                tmp = [0]
            for j from 0 <= j < len(tmp):
                if len(tmp) == 2:
                    if events[i].events & tmp[j]:
                        new_e.events = events[i].events & ~(tmp[j])

                if new_e.events & EPOLLERR or new_e.events & EPOLLHUP:
                    #print 'epoll_wait event >>>>>> %s for %s' % (new_e.events, new_e.data.fd)
                    new_e.events = new_e.events & ~(EPOLLHUP)
                    new_e.events = new_e.events & ~(EPOLLERR)

                _py_event = py_event()
                _py_event.__fast_init__(&new_e)
                ek = event_key (new_e.events, new_e.data.fd)

                try:
                    co = self.event_map[ek]
                except KeyError:
                    pass
                    #W ('un-handled event: fd=%s events=%s\n' % (new_e.data.fd, new_e.events))
                else:
                    if isinstance (co, coro):
                        co._schedule (_py_event)
                    else:
                        # assumes kt.target is a callable object
                        _spawn(co, (_py_event,), {})
                    del self.event_map[ek]
