package protocol

// The idea for the interception "system" is to mimic packet loss, out-of-order packets
// and other conditions that can happen in real networks specifically for how the 
// transmission module should deal with it. This will not be a realistic network emulator.
// 
// We'll achieve this by making a new Send and Recv stream that instead of writing onto a UDP
// socket, it'll somehow intercept the packets going from the Send -> Recv, whether that's through a 
// own interception queue or not is yet to be decided. Then we apply some effect on the packet, like
// drop, lag, change contents etc, and make the packets available for the recv side when the effect has
// been applied.
//
// The main advantage of doing it like this is that we get complete control over both sides, and can ensure
// that everything is synced to what we expect. 
// An example is: We want to transmit a large data structure that will be way larger than MTU so we need to split
// into, let's say 10 fragment packets. We now want to test if our protocol implementation can deal with packet loss
// properly, so we drop the third fragment. On the receiving side we can now assert that only 9 of the fragments should
// be received. Now we can do something similar for out-of-order, lag etc.

Interception_Send_Stream :: struct {}

Interception_Recv_Stream :: struct {}
