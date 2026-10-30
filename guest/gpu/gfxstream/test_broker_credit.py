import asyncio
import unittest
from test_live_broker import broker, Writer, Kind, Decoder


class BrokerCreditTests(unittest.IsolatedAsyncioTestCase):
    async def test_reservations_count_against_queue_and_release_wakes_waiter(self):
        session = broker.Session(None, b'a'*16, 1, None, Writer())
        credits = []
        while (session.reserved_bytes + broker.DATA_CREDIT_BYTES <=
               broker.MAX_QUEUED_BYTES - broker.CONTROL_HEADROOM_BYTES):
            credits.append(await session.reserve_data())
        waiting = asyncio.create_task(session.reserve_data())
        await asyncio.sleep(0)
        self.assertFalse(waiting.done())
        self.assertLessEqual(session.reserved_bytes + session.pending_bytes, broker.MAX_QUEUED_BYTES)
        # Existing control traffic sees all outstanding reservations too.
        with self.assertRaises(BufferError): session.enqueue_frame(bytes(broker.MAX_QUEUED_BYTES))
        credits.pop().release()
        credits.append(await asyncio.wait_for(waiting, 1))
        for credit in credits: credit.release()
        self.assertEqual((session.reserved_count, session.reserved_bytes), (0, 0))
        session.bindings.finish(session.binding_generation)

    async def test_commit_preserves_sequence_and_waits_for_actual_drain(self):
        class HeldWriter(Writer):
            def __init__(self): super().__init__(); self.entered=asyncio.Event(); self.allowed=asyncio.Event()
            async def drain(self): self.entered.set(); await self.allowed.wait()
        writer=HeldWriter(); session=broker.Session(None,b'a'*16,1,None,writer)
        credit=await session.reserve_data()
        session.send(Kind.DATA,1,1,b'x'*65536,credit=credit)
        self.assertFalse(credit.active)
        self.assertEqual(session.reserved_bytes,0)
        queued=session.pending_bytes
        sender=asyncio.create_task(session.send_loop())
        try:
            await asyncio.wait_for(writer.entered.wait(),1)
            self.assertEqual(session.pending_bytes,queued)
            self.assertEqual(session.pending_count,1)
            writer.allowed.set(); await asyncio.wait_for(session.pending.join(),1)
            self.assertEqual((session.pending_bytes,session.pending_count),(0,0))
            self.assertEqual(session.sequence,2)
        finally:
            sender.cancel(); await asyncio.gather(sender,return_exceptions=True)
            session.bindings.finish(session.binding_generation)

    async def test_failed_sender_wakes_credit_waiters_without_successful_drain(self):
        class BrokenWriter(Writer):
            async def drain(self): raise OSError('broken')
        session=broker.Session(None,b'a'*16,1,None,BrokenWriter())
        credits=[]
        for _ in range(14): credits.append(await session.reserve_data())
        session.send(Kind.DATA,1,1,b'x'*65536,credit=credits[0])
        waiter=asyncio.create_task(session.reserve_data()); await asyncio.sleep(0)
        self.assertFalse(waiter.done())
        sender=asyncio.create_task(session.send_loop())
        try:
            with self.assertRaises(OSError): await sender
            with self.assertRaises(ConnectionError): await asyncio.wait_for(waiter,1)
            self.assertGreater(session.pending_bytes,0)
        finally:
            for credit in credits: credit.release()
            session.bindings.finish(session.binding_generation)

    async def test_credit_cannot_be_reused_or_transferred(self):
        first=broker.Session(None,b'a'*16,1,None,Writer())
        other=broker.Session(None,b'b'*16,2,None,Writer())
        credit=await first.reserve_data()
        try:
            with self.assertRaises(RuntimeError): other.send(Kind.DATA,1,1,b'x',credit=credit)
            self.assertTrue(credit.active)
            first.send(Kind.DATA,1,1,b'x',credit=credit)
            with self.assertRaises(RuntimeError): first.send(Kind.DATA,1,1,b'x',credit=credit)
            self.assertEqual(first.sequence,2)
        finally:
            credit.release()
            first.bindings.finish(first.binding_generation)
            other.bindings.finish(other.binding_generation)

    async def test_cancelled_capacity_wait_does_not_own_credit(self):
        session=broker.Session(None,b'a'*16,1,None,Writer())
        credits=[await session.reserve_data() for _ in range(14)]
        waiting=asyncio.create_task(session.reserve_data()); await asyncio.sleep(0)
        waiting.cancel(); await asyncio.gather(waiting,return_exceptions=True)
        self.assertEqual(session.reserved_count,14)
        for credit in credits: credit.release()
        self.assertEqual(session.reserved_count,0)
        session.bindings.finish(session.binding_generation)


if __name__=='__main__': unittest.main()
