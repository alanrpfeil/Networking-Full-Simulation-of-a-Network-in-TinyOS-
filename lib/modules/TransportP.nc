#include "../../includes/command.h"
#include "../../includes/packet.h"
#include "../../includes/CommandMsg.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/protocol.h"
#include "../../includes/TCP.h"
#include <Timer.h>

#define TCP_PACKET_PAYLOAD_SIZE 1024
#define TCP_APP_READ_SIZE 10

module TransportP {
	provides interface Transport;
	//uses interface Hashmap<socket_store_t> as socketPort;
	uses interface SimpleSend as Sender;	//used for forwarding with project 2 LSR
	uses interface NeighborDiscovery;
	uses interface Timer<TMilli> as myTimer;
	uses interface LinkStateRouting;
	//uses interface Receive as Receiver;		//used for receiving TCP packets; will define
	uses interface Hashmap<uint8_t> as SocketMap;
	uses interface Random;	//for getting lastRead/Written as a random to avoid eventual conflict
}

implementation {
	socket_store_t sockets[10];	//array of sockets; 1 per port
	
	pack ipPack;				//packet on the IP layer
	TCP tcpPack;				//packet on the transport layer; special header type
	bool ports[10];				//--
	uint16_t dropCounter = 1;	//--
	
	void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length) {
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
   
	//Absolute Difference
	uint32_t absDiff(uint32_t a, uint32_t b) { if(a < b) { return b - a;} else { return a - b;}}
	//Minimum of 2 values
	uint32_t min(uint32_t a, uint32_t b) { if(a <= b) { return a;} else { return b;}}
	//Maximum of 2 values
    uint32_t max(uint32_t a, uint32_t b) { if(a <= b) { return b;} else { return a;}}
	
	void addConnection(uint8_t fd, uint8_t connection) {
		uint8_t i;
		for (i = 0; i < 9; i++) {	//9 is max connNums
			if (sockets[fd - 1].connectionQueue[i] == 0) {
				sockets[fd - 1].connectionQueue[i] = connection;
				break;
			}
		}
	}
	
	uint8_t findSocket(uint8_t src, uint8_t srcPort, uint8_t dest, uint8_t destPort) {
        uint32_t socketNum = (((uint32_t)src) << 24) | (((uint32_t)srcPort) << 16) | (((uint32_t)dest) << 8) | (((uint32_t)destPort));	//referencing concatenated data
		return call SocketMap.get(socketNum);
    }
	
	uint16_t getReceiverReadable(uint8_t fd) {
		uint16_t lastRead, nextExpected;
		lastRead = sockets[fd - 1].lastRead % SOCKET_BUFFER_SIZE;
		nextExpected = sockets[fd - 1].nextExpected % SOCKET_BUFFER_SIZE;
		if (lastRead < nextExpected) {
			return (nextExpected - lastRead - 1);
		}
		else {
			return (SOCKET_BUFFER_SIZE - lastRead + nextExpected - 1);
		}
	}
	
	uint16_t getReceiveBufferAvailable(uint8_t fd) {
		//gets the receive buff avail too
		uint16_t receiveBufferAvailable;
		uint8_t lastRead, lastRcvd;
		lastRead = sockets[fd - 1].lastRead % 128;
		lastRead = sockets[fd - 1].lastRcvd % 128;
		if (lastRead <= lastRcvd) {
			return (lastRead + (SOCKET_BUFFER_SIZE - lastRcvd) - 1);
		}
		else {
			return (lastRead - lastRcvd - 1);
		}
	}
	
	uint16_t getSenderDataInFlight(uint8_t fd) {
		uint16_t lastAck, lastSent;
		lastAck = sockets[fd - 1].lastAck % SOCKET_BUFFER_SIZE;
		lastSent = sockets[fd - 1].lastSent % SOCKET_BUFFER_SIZE;
		if (lastAck <= lastSent) {
			return (lastSent - lastAck);
		}
		else {
			return (SOCKET_BUFFER_SIZE - lastAck + lastSent);
		}
	}
	
	uint16_t getSendBufferOccupied(uint8_t fd) {	//returns amount of bytes to send
		uint8_t lastSent, lastWritten;
		lastSent = sockets[fd - 1].lastSent % SOCKET_BUFFER_SIZE;
		lastWritten = sockets[fd - 1].lastWritten % SOCKET_BUFFER_SIZE;
		if (lastSent <= lastWritten) {
			return (lastWritten - lastSent);
		}
		else {
			return (lastWritten + (SOCKET_BUFFER_SIZE - lastSent));
		}
	}
	
	uint16_t getSendBufferAvailable(uint8_t fd) {
		uint8_t lastAck, lastWritten;
	
		lastAck = sockets[fd - 1].lastAck % 128;
		lastWritten = sockets[fd - 1].lastWritten % 128;
		
		printf("lastAck: %u, lastWritten: %u\n", lastAck, lastWritten);
		if (lastAck <= lastWritten) {
			return (lastAck + (128 - lastWritten) - 1);
		}
		else {
			return (lastAck - lastWritten - 1);
		}
	}
	
	uint8_t calcAdvWindow(uint8_t fd) {
		return SOCKET_BUFFER_SIZE - getReceiverReadable(fd) - 1;
	}
	
	uint8_t calcEffWindow(uint8_t fd) {
		return sockets[fd - 1].advertisedWindow - getSenderDataInFlight(fd);
	}
	
	uint8_t calcCongWindow(uint8_t fd) {
		return (sockets[fd - 1].cwnd * TCP_PACKET_PAYLOAD_SIZE) + ((sockets[fd - 1].cwndRemainder * TCP_PACKET_PAYLOAD_SIZE) / sockets[fd - 1].cwnd);
	}
	
	void calcRTT(uint8_t fd, uint16_t ack) {	//getting RTT between connection...
		uint32_t now = call myTimer.getNow();
		if (sockets[fd - 1].RTT_SEQ == ack && sockets[fd - 1].IS_VALID_RTT) {
			sockets[fd - 1].RTT = ((TCP_RTT_ALPHA) * (sockets[fd - 1].RTT) + (100 - TCP_RTT_ALPHA) * (now - sockets[fd - 1].RTX)) / 100;
			sockets[fd - 1].RTT_VAR = ((TCP_RTT_BETA) * (sockets[fd - 1].RTT_VAR) + (100 - TCP_RTT_BETA) * absDiff(sockets[fd - 1].RTT_VAR, now - sockets[fd - 1].RTX)) / 100;
		}
		else if (sockets[fd - 1].RTT_SEQ == ack) {
			sockets[fd - 1].IS_VALID_RTT = TRUE;
		}
	}
	
	void calcRTO(uint8_t fd) {	//Running Time Objective; like a timeout
		sockets[fd - 1].RTT_SEQ = sockets[fd - 1].lastSent + 1;
		sockets[fd - 1].RTX = call myTimer.getNow();
		sockets[fd - 1].RTO = sockets[fd - 1].RTX + sockets[fd - 1].RTT + (4 * sockets[fd - 1].RTT_VAR);
	}
	
	uint8_t sendTCPPacket(uint8_t fd, uint8_t flags) {
		pack newPack;		//Pack to hold TCP pack payload
		uint16_t immHop;	//next hop location; immediate hop
		uint8_t length;
		uint8_t bytes = 0;
		uint8_t* payload = (uint8_t*)tcpPack.payload;
		tcpPack.srcPort = sockets[fd - 1].src.port;
		tcpPack.destPort = sockets[fd - 1].dest.port;
		tcpPack.flags = flags;
		tcpPack.advwin = calcAdvWindow(fd);
		tcpPack.ack = sockets[fd - 1].nextExpected;
		
		if (flags == UPD) {
			length = 8;
			//printf("SendBuff Str: %s\n", sockets[fd-1].sendBuff);
			memcpy(tcpPack.payload, sockets[fd - 1].sendBuff, length);
			//sprintf("tcpPack.payload Str: %s\n", tcpPack.payload);
			tcpPack.length = length;
		}
		
		if (flags == SYN) {
			tcpPack.seq = sockets[fd - 1].lastSent;			//initiate seqnum to start sync
		}
		else {
			tcpPack.seq = sockets[fd - 1].lastSent + 1;		//Seqnum is equal to next expected seqnum
		}
		
		if (flags == DATA) {
			//printf("Data Attempting to Stream\n");
			//length = min(min(calcEffWindow(fd), calcCongWindow(fd) - getSendBufferOccupied(fd)), min(getSendBufferOccupied(fd), TCP_PACKET_PAYLOAD_SIZE));
			length = 18;
			if (length == 0) {			//if no data, drop
				//printf("Yo boi\n"); //debugging purposes...
				return 0;
			}
			//printf("SendBuff Str: %s\n", sockets[fd-1].sendBuff);
			memcpy(tcpPack.payload, sockets[fd - 1].sendBuff, length);
			//sprintf("tcpPack.payload Str: %s\n", tcpPack.payload);
			tcpPack.length = length;
		}
		//printf("Dest: %u, SrcPort: %u, DestPort: %u\n", sockets[fd - 1].dest.addr, tcpPack.srcPort, tcpPack.destPort);
		makePack(&newPack, TOS_NODE_ID, sockets[fd - 1].dest.addr, BETTER_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPack, sizeof(TCP));
		immHop = call LinkStateRouting.getNextHopTo(sockets[fd - 1].dest.addr);
		//printf("immHop: %u\n", immHop);
		//dbg(TRANSPORT_CHANNEL, "Forwarding TCP Packet From Node %u to Node %u's Port: %u\n", TOS_NODE_ID, sockets[fd-1].dest.addr, sockets[fd-1].dest.port);
		call Sender.send(newPack, immHop);	//send out IP packet
		return bytes;	//sent # Bytes
	}
	
	void sendWindow(uint8_t fd) {
		uint16_t bytesRemaining = min(calcCongWindow(fd) - getSenderDataInFlight(fd), min(getSendBufferOccupied(fd), calcEffWindow(fd)));
		uint8_t bytesSent;
		bool firstPacket = TRUE;
		while (bytesRemaining > 0 && bytesSent > 0 && calcCongWindow(fd) > getSenderDataInFlight(fd)) {
			bytesSent = sendTCPPacket(fd, DATA);
			bytesRemaining -= bytesSent;
			if (firstPacket == TRUE && bytesSent > 0) {
				calcRTO(fd);
				firstPacket = FALSE;
			}
		}
	}

	bool handleFT(uint8_t fd, uint16_t ack) {	//handling fast retransmission
		uint8_t temp;
		//Fast Retransmission: When duplicate (usually 3rd, or in this case TCP_FT_DUP) ACK is received, set ssthresh to one-half of the minimum of the current congestion window
		if (sockets[fd - 1].duplicateAck.seq == ack) {	//checking for duplicate
			sockets[fd - 1].duplicateAck.count++;
			if (sockets[fd - 1].duplicateAck.count == TCP_FT_DUP) {	//TCP_FT_DUP = 3; see above comment.
				temp = calcCongWindow(fd);
				
				//updating socket vars for retransmit and congestion control...
				//go back to last non-congesting cwnd, or go to min cwnd if below it
				sockets[fd - 1].cwnd = max((temp >> 1) / TCP_PACKET_PAYLOAD_SIZE, TCP_MIN_CWND);
				//fixing window if remainder
				sockets[fd - 1].cwndRemainder = (((temp >> 1) % TCP_PACKET_PAYLOAD_SIZE) * sockets[fd - 1].cwnd) / TCP_PACKET_PAYLOAD_SIZE;
				
				//setting new threshold for new cwnd
				sockets[fd - 1].ssthresh = calcCongWindow(fd);	//ssthresh where AIMD takes over
				
				//LECTURE SLIDES ON CONGESTION CONTROL//
				//ssthresh = cwnd after cwnd /= 2 on loss (above)
				//switch to AIMD once cwndpasses ssthresh (below)
				
				sockets[fd - 1].cwndStrategy = AIMD;	//beyond ssthresh now
				sockets[fd - 1].lastSent = sockets[fd - 1].lastAck;
				//sending cwnd to host now +1 per RTT
				sendWindow(fd);
				
				return TRUE;
			}
			else if (sockets[fd - 1].duplicateAck.count > TCP_FT_DUP) {	//if more ACK than 3
				sockets[fd - 1].cwndRemainder++;	//incr remainder to fix new cwnd
				if (sockets[fd - 1].cwnd == sockets[fd - 1].cwndRemainder) {
					sockets[fd - 1].cwnd++;
					sockets[fd - 1].cwndRemainder = 0;
				}
				return TRUE;
			}
		}
		else {	//base case if duplicate found but duplicateAck.seq != ack; set it so to get trapped by next iteration
			sockets[fd - 1].duplicateAck.seq = ack;
			sockets[fd - 1].duplicateAck.count = 1;
		}
		return FALSE;
	}

	void readInData(uint8_t fd, TCP* tcp_rcvd) {
		uint16_t bytesRead = 0;
		uint8_t* payload = tcp_rcvd->payload;
		
		if (getReceiveBufferAvailable(fd) < tcp_rcvd->length || sockets[fd - 1].nextExpected != tcp_rcvd->seq || tcp_rcvd->flags !=DATA) {
			return;
		}
		//printf("String Now S0: %s\n", payload);
		dropCounter++;
		
		memcpy(sockets[fd - 1].rcvdBuff, payload, tcp_rcvd->length);

		dbg(TRANSPORT_CHANNEL, "Server Buffer Receives: %s\n", sockets[fd - 1].rcvdBuff);
		sockets[fd - 1].nextExpected = sockets[fd - 1].lastRcvd + 1;
		sockets[fd - 1].advertisedWindow = calcAdvWindow(fd);
		
		if (sockets[fd - 1].advertisedWindow == 0) {
			sockets[fd - 1].deadlockAck = TRUE;
			sockets[fd - 1].RTO = call myTimer.getNow() + TCP_DEADLOCK_ACK_RTO;
		}
	}

	void zeroSocket(uint8_t fd) {
		uint8_t i;
		sockets[fd - 1].state = CLOSED;
		sockets[fd - 1].src.addr = 0;
		sockets[fd - 1].src.port = 0;
		sockets[fd - 1].dest.addr = 0;
		sockets[fd - 1].dest.port = 0;
		for (i = 0; i < MAX_NUM_OF_SOCKETS - 1; i++) {
			sockets[fd - 1].connectionQueue[i] = 0;
		}
		for (i = 0; i < SOCKET_BUFFER_SIZE; i++) {
			sockets[fd - 1].sendBuff[i] = 0;
			sockets[fd - 1].rcvdBuff[i] = 0;
		}
		i = (uint8_t)(call Random.rand16() % (SOCKET_BUFFER_SIZE<<1));
        sockets[fd-1].lastWritten = i;
        sockets[fd-1].lastAck = i;
        sockets[fd-1].lastSent = i;
        sockets[fd-1].lastRead = 0;
        sockets[fd-1].lastRcvd = 0;
        sockets[fd-1].nextExpected = 0;
        sockets[fd-1].RTT = TCP_INITIAL_RTT;
        sockets[fd-1].RTT_VAR = TCP_INITIAL_RTT_VAR;
        sockets[fd-1].RTO = TCP_INITIAL_RTO;
        sockets[fd-1].RTT_SEQ = i;
        sockets[fd-1].RTX = 0;
        sockets[fd-1].IS_VALID_RTT = TRUE;
        sockets[fd-1].advertisedWindow = SOCKET_BUFFER_SIZE - 1;
        sockets[fd-1].cwnd = TCP_MIN_CWND;
        sockets[fd-1].cwndRemainder = 0;
        sockets[fd-1].cwndStrategy = SLOW_START;
        sockets[fd-1].ssthresh = TCP_MAX_CWND * TCP_PACKET_PAYLOAD_SIZE;
        sockets[fd-1].duplicateAck.seq = 0;
        sockets[fd-1].duplicateAck.count = 0;
        sockets[fd-1].deadlockAck = FALSE;
		// everything is now "zero'd"
	}
	
	event void myTimer.fired() {
		uint8_t synCount; 	//control counter used for stopping too many retransmissions of SYNs being sent to unresponsive/non-existing servers.
        uint8_t i;
        if(call myTimer.isOneShot()) {
            dbg(TRANSPORT_CHANNEL, "Transfer Beginning on Node %u\n", TOS_NODE_ID);
            call myTimer.startPeriodic(512 + (uint16_t) (call Random.rand16()%100));
        }
        //Iterate over sockets
        //If timeout (>RTT) we need to retransmit (might have to handleFT)
		
		//Otherwise if a connection is established we should attempt TCP packet send
        for(i = 0; i < 10; i++) {
            if(sockets[i].RTO < call myTimer.getNow()) {
                // dbg(TRANSPORT_CHANNEL, "Retransmitting!\n");
                switch(sockets[i].state) {
                    case ESTABLISHED:
                        if(sockets[i].lastSent != sockets[i].lastAck && sockets[i].type == CLIENT && getSenderDataInFlight(i+1) > 0) {
                            // dbg(TRANSPORT_CHANNEL, "Resending at %u. Data in flight %u\n", sockets[i].lastSent+1, getSenderDataInFlight(i+1));
                            // Go back N
                            sockets[i].lastSent = sockets[i].lastAck;
                            // Adjust ssthresh, cwnd
                            sockets[i].ssthresh = max(calcCongWindow(i+1) >> 1,TCP_PACKET_PAYLOAD_SIZE);
                            sockets[i].cwnd = TCP_MIN_CWND;
                            sockets[i].cwndRemainder = 0;
                            sockets[i].cwndStrategy = SLOW_START;
                            // Resend window
                            sendWindow(i+1);
                            // Double the RTO
                            sockets[i].RTO += sockets[i].RTT + (4 * sockets[i].RTT_VAR);
                            // Don't calc RTT on retransmission
                            sockets[i].IS_VALID_RTT = FALSE;
                            continue;
                        } else if(sockets[i].type == SERVER && sockets[i].deadlockAck) {
                            // dbg(TRANSPORT_CHANNEL, "Sending deadlock ACK. Adv. Win. %u\n", calcAdvWindow(i+1));
                            sendTCPPacket(i+1, ACK);
                            sockets[i].RTO = call myTimer.getNow() + TCP_DEADLOCK_ACK_RTO;                            
                        }
                        break;
                    case SYN_SENT:
                        // Resend SYN
						if (synCount < 3) {
                        sendTCPPacket(i+1, SYN);
						synCount++;
                        calcRTO(i+1);
						} else {
							dbg(TRANSPORT_CHANNEL, "SYN is Not Being Received by Desired Server; Closing Port.\n");
							sockets[i].state = CLOSED;	//Stop trying to connect
							synCount = 0;	//reset SYN counter
							break;
						}
                        break;
                    case SYN_RCVD:
                        // Resend SYN_ACK
                        sendTCPPacket(i+1, SYN_ACK);
                        calcRTO(i+1);
                        break;
                    case CLOSE_WAIT:
                        // Resend FIN
                        dbg(TRANSPORT_CHANNEL, "Sending FIN Back to Client. Socket State is Now LAST_ACK.\n");
                        sendTCPPacket(i+1, FIN);
                        sockets[i].state = LAST_ACK;
                        // Set final RTO
                        sockets[i].RTO = call myTimer.getNow() + (4 * sockets[i].RTT);
                        break;
						//FIN_WAIT_1 is dealt with upon receiving ACK back from server, dealt the same as LAST_ACK.
					case FIN_WAIT_1:
                    case LAST_ACK:
                        //Resend FIN until Transport.receive deals with ACK received from client
                        sendTCPPacket(i+1, FIN);
                        calcRTO(i+1);
                        break;
                    case TIME_WAIT:
                        //Timeout: TIME_WAIT is up.
                        sockets[i].state = CLOSED;	//now closed
                        dbg(TRANSPORT_CHANNEL, "TIME_WAIT is up; Client and Port Now Fully Closed.\n");
                }
            }
            if(sockets[i].state == ESTABLISHED && sockets[i].type == CLIENT) {
                // Send window
                sendWindow(i+1);
            }
        }
    }

	uint8_t cloneSocket(uint8_t fd, uint16_t addr, uint8_t port) {
		uint8_t i;
		
		for (i = 0; i < 10; i++) {
			if (sockets[i].state == CLOSED) {
				sockets[i].src.addr = sockets[fd - 1].src.addr;
				sockets[i].src.port = sockets[fd - 1].src.port;
				sockets[i].dest.addr = addr;
				sockets[i].dest.port = port;
				return (i + 1);
			}
		}
		return 0;
	}
	
	command void Transport.start() {
        uint8_t i;
        call myTimer.startOneShot(60*1024);
        for(i = 0; i < 10; i++) {
            zeroSocket(i+1);
        }
    }
	
	command void Transport.sendWhisper(uint8_t fd, uint8_t flag) {
		sendTCPPacket(fd, flag);
		//printf("Here\n");
	}
	
	command void Transport.receiveMessage(uint8_t* buffer) {
		dbg(TRANSPORT_CHANNEL, "Message Received: %s\n", buffer);
	}
	
	void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length);
	
	command socket_t Transport.socket() {
		uint8_t i;
		for (i = 0; i < 10; i++) {
			//printf("This is the state of %d: %u\n", i, sockets[i].state);
			if (sockets[i].state == CLOSED) {
				//printf("i = %u\n", i);
				//dbg(TRANSPORT_CHANNEL, "hello\n");
				sockets[i].state = LISTEN;
				return (socket_t) i+1;
			}
		}
		return 0;
	}
		
	command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
		uint32_t socketNum = 0;
		
		if (fd == 0 || fd > 10) {	//identifies if fd is valid
			return FAIL;
		}
		
		//printf("fd: %u\n", fd);
		if (sockets[fd - 1].state == LISTEN && !ports[addr->port]) {	// makes sure socket is listening and port is unused
			sockets[fd - 1].src.addr = addr->addr;
			sockets[fd - 1].src.port = addr->port;
			//sockets[fd - 1].state = LISTEN;		//Already listening
			socketNum = (((uint32_t)addr->addr) << 24) | (((uint32_t)addr->port) << 16);
			call SocketMap.insert(socketNum, fd);	//Push into socket map
			ports[addr->port] = TRUE;	//Port is now in use
			return SUCCESS;
		}
		return FAIL;
	}
		
	command socket_t Transport.accept(socket_t fd) {
		uint8_t i;
		uint8_t connection;
		//printf("fd: %u\n", fd);
		
		if (fd == 0 || fd > 10) {	//identifies if fd is valid
			return 0;
		}
		
		for (i = 0; i < (10 - 1); i++) {
			if (sockets[fd - 1].connectionQueue[i] != 0) {		//if queue is not empty
				//printf("popping from connection queue\n");
				connection = sockets[fd - 1].connectionQueue[i];
				while (++i < (10-1) && sockets[fd - 1].connectionQueue[i] != 0) {
					sockets[fd - 1].connectionQueue[i - 1] = sockets[fd - 1].connectionQueue[i];
				}
				sockets[fd - 1].connectionQueue[i - 1] = 0;
				return (socket_t) connection;
			}
		}
		return 0;
	}
		
	command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
		uint16_t bytes = bufflen;		//bytes written
		uint8_t lastAck, lastWritten;
		
		//printf("buff: %u\n", *buff);
		
		if (fd == 0 || fd > 19 || sockets[fd - 1].state != ESTABLISHED) {
			dbg(TRANSPORT_CHANNEL, "Cannot Write to Node\n");
			return 0;
		}

		memcpy(sockets[fd - 1].sendBuff, buff, bufflen);
		bytes = bufflen;
		
		return bytes;
	}

	command error_t Transport.receive(pack* package) {
		uint8_t fd, new_fd;
		uint8_t src = package->src;
		uint32_t socketNum = 0;
		TCP* tcp_rcvd = (TCP*) &package->payload;
		//uint8_t* data;
		//dbg(TRANSPORT_CHANNEL, "flag for packet received: %u. socket state of this node: %u\n", tcp_rcvd->flags, sockets[fd-1].state);
		//dbg(TRANSPORT_CHANNEL, "We're here\n");
		switch(tcp_rcvd->flags) {
			case DATA:
				fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
				switch(sockets[fd - 1].state) {	//we have to make sure we handle different socket states properly/respectively
					case SYN_RCVD:		//connection attempted
						dbg(TRANSPORT_CHANNEL, "Connection Has Been Established.\n");
						sockets[fd - 1].state = ESTABLISHED;
					case ESTABLISHED:	//connection made
						if (sockets[fd - 1].deadlockAck && tcp_rcvd->seq == sockets[fd - 1].nextExpected) {
							sockets[fd - 1].deadlockAck = FALSE;
						}
						//printf("TCP payload: %s\n", tcp_rcvd->payload);
						readInData(fd, tcp_rcvd);
						//printf("read data\n");
						sendTCPPacket(fd, ACK);
						//printf("Sent ACK\n");
						return SUCCESS;
				}
				break;
			case ACK:	//acknowledgement; 3-way handshake or close
				//first we find the file descriptor:
				fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
				if (fd == 0) {	//if empty/invalid fd...
					break;	//exit state handling
				}
				calcRTT(fd, tcp_rcvd->ack);	//get RTT
				switch(sockets[fd-1].state) {
					case SYN_RCVD:
						dbg(TRANSPORT_CHANNEL, "Acknowledgement received on node %u with destination port: %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
						//we can now transition state to ESTABLISHED for the connection...
						sockets[fd-1].state = ESTABLISHED;
						dbg(TRANSPORT_CHANNEL, "Connection has been established; awaiting Bytestream...\n");
						
						//Server sending (initiating) stream:
						//*data = 100;
						//Transport.write(clients[i].fd, data, 1024);
						
						//sendTCPPacket(fd, DATA);
						
						return SUCCESS;
					case ESTABLISHED: //if connection already made/present
						if (!handleFT(fd, tcp_rcvd->ack)) {	//fast retransmission when/if necessary
							//increase congestion window
							switch (sockets[fd-1].cwndStrategy) {
								case SLOW_START:
									sockets[fd-1].cwnd++; //adding to congestion window
									if (calcCongWindow(fd) >= sockets[fd-1].ssthresh) {
										sockets[fd-1].cwndStrategy = AIMD; //if beyond threshhold of congestion window we use Additive Increase/Multiply control to handle window
									}
								break;
								case AIMD:
									//checking for if cwnd can even be expanded...
									if (sockets[fd-1].cwnd < TCP_MAX_CWND) {
										sockets[fd-1].cwndRemainder++; //expanding remainder
									}
									//if congestion window == congestion window remainder...
									if (sockets[fd-1].cwnd == sockets[fd-1].cwndRemainder) {
										sockets[fd-1].cwnd++;				//incr window
										sockets[fd-1].cwndRemainder = 0;	//resolved remainder into new window size; no remainder now
									}
								
							}
						}
						//need to update last acknowledgement and advertised window
						sockets[fd-1].lastAck = tcp_rcvd->ack - 1;
						sockets[fd-1].advertisedWindow = tcp_rcvd->advwin;
						dbg(TRANSPORT_CHANNEL, "ACK Received. Continuing Transmission\n");
						
						//INSERT
						
						return SUCCESS;
					
					case FIN_WAIT_1:	//going to attempt close
						dbg(TRANSPORT_CHANNEL, "ACK received on node %u via port %u. Going to FIN_WAIT_2.\n", TOS_NODE_ID, tcp_rcvd->destPort);
						sockets[fd-1].state = FIN_WAIT_2; //updating state of socket... wait once more
						return SUCCESS;	//ack received and going to finwait2
					
					case CLOSING:	//case may be covered; potentially unnecessary
						dbg(TRANSPORT_CHANNEL, "Received last ack. Going to TIME_WAIT.\n");
						sockets[fd-1].state = TIME_WAIT;  //updating state of socket...
						sockets[fd-1].RTO = call myTimer.getNow() + (4 * sockets[fd-1].RTT);
						return SUCCESS;
					
					case LAST_ACK:
						sockets[fd-1].state = CLOSED; //updating state of socket...
						//we're done with this connection now; close bytestream/connection!
						zeroSocket(fd);	//since closed we nullify the socket
						dbg(TRANSPORT_CHANNEL, "LAST_ACK Received. Connection is Now Fully Closed.\n");
						return SUCCESS;
				}
				break;
			case SYN:
				//Getting existing socket from hashmap...
				//dbg(TRANSPORT_CHANNEL, "State is now: %u\n", sockets[fd-1].state);
				fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, package->src, tcp_rcvd->srcPort);
				
				//printf("FD: %u\n", fd);
				//dbg(TRANSPORT_CHANNEL, "State is now: %u\n", sockets[fd-1].state);
				
				if (fd == 0) { //as long as valid fd...
					break;	//INVALID FD; NOT FOUND
				}
				
				switch (sockets[fd-1].state) {
					case ESTABLISHED:	//case if a connection already exists
						dbg(TRANSPORT_CHANNEL, "A Connection Already Exists; Returning.");
						break;
					case LISTEN:	//if port listening and SYN received from a client...
						new_fd = cloneSocket(fd, package->src, tcp_rcvd->srcPort);	//grab fd
						if (new_fd > 0) {
							//as long as valid fd returned...
							//create socket
							printf("adding connection fd: %u, new_fd: %u\n", fd, new_fd);
							addConnection(fd, new_fd);
						
							sockets[new_fd-1].state = SYN_RCVD;	//updating state of socket made
							sockets[new_fd-1].lastRead = tcp_rcvd->seq;
							sockets[new_fd-1].lastRcvd = tcp_rcvd->seq;
							sockets[new_fd-1].nextExpected = tcp_rcvd->seq + 1;
						
							sendTCPPacket(new_fd, SYN_ACK); //send back acknowledgement for 3-way HS
							socketNum = (((uint32_t)TOS_NODE_ID) << 24) | (((uint32_t)tcp_rcvd->destPort) << 16) | (((uint32_t)src) << 8) | (((uint32_t)tcp_rcvd->srcPort)); //concatenating for hashmap
							dbg(TRANSPORT_CHANNEL, "SYN Acknowledgement Sent Back to Client Node %u's Port %u\n", src, tcp_rcvd->srcPort);
							call SocketMap.insert(socketNum, new_fd);
							return SUCCESS; //phew, done with making socket here.
						}
				}
				break;
			case SYN_ACK:                
				fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
				if(fd == 0) {
					break;	//if invalid fd found...
				}
			
				if(sockets[fd-1].state == SYN_SENT) {
					dbg(TRANSPORT_CHANNEL, "SYN_ACK received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
					sockets[fd-1].advertisedWindow = tcp_rcvd->advwin; //setting advwin          
					sockets[fd-1].state = ESTABLISHED;	//connection now established. Hurray!
				
					//follow-up ACK:
					calcRTT(fd, tcp_rcvd->ack);     
					sendTCPPacket(fd, ACK);	//we have to send ACK back to node src
					calcRTO(fd);
					dbg(TRANSPORT_CHANNEL, "ACK sent back to node %u's Port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
					dbg(TRANSPORT_CHANNEL, "Connection has been established.\n");
					
					//starting bytestream now:
					
					//sendTCPPacket(fd, DATA);
					
					return SUCCESS; //done for this socket state.
				}
				break;
			case FIN:
				//dif types of finish states; waiting on fin (multiple stages) or closed fin.
				fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);     
                switch (sockets[fd-1].state) {
                    case ESTABLISHED:
                        dbg(TRANSPORT_CHANNEL, "Attempting a closing wait. Sending ACK to finish closing of connection.\n");
						
                        //Sending aforementioned acknowledgement...
                        sendTCPPacket(fd, ACK);                        
                        calcRTO(fd);
                        sockets[fd-1].state = CLOSE_WAIT;	//updating state
                        return SUCCESS;
						
                    case FIN_WAIT_1:
                        dbg(TRANSPORT_CHANNEL, "Final FIN received. Sending ACK back and Going Into State of TIME_WAIT.\n");
                        //Sending aforementioned acknowledgement...
                        sendTCPPacket(fd, ACK);
                        sockets[fd-1].state = TIME_WAIT;	//updating state of socket
                        sockets[fd-1].RTO = call myTimer.getNow() + (4 * sockets[fd-1].RTT);
                        return SUCCESS;
						
                    case FIN_WAIT_2:
					//same handling as TIME_WAIT
                    case TIME_WAIT:	//previous case made ^ above ^
                        sendTCPPacket(fd, ACK); //Sending acknowledgement...
                        if(sockets[fd-1].state != TIME_WAIT) {	//should already be in timewait from above code for FIN_WAIT_1... making sure.
                            sockets[fd-1].state = TIME_WAIT;
                            sockets[fd-1].RTO = call myTimer.getNow() + (4 * sockets[fd-1].RTT);
                        }
                        return SUCCESS;
				}
				break;
			case FIN_ACK:
				// Find socket fd
				fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
				switch(sockets[fd-1].state) {
					case FIN_WAIT_1:
					
						sendTCPPacket(fd, ACK); //Sending final acknowledgement...
						return SUCCESS;       //done. fully closed.      
				}
				break;
			case UPD:
				
				fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
				switch(sockets[fd - 1].state) {	//we have to make sure we handle different socket states properly/respectively
					case SYN_RCVD:		//connection attempted
						dbg(TRANSPORT_CHANNEL, "Connection Has Been Established.\n");
						sockets[fd - 1].state = ESTABLISHED;
					case ESTABLISHED:	//connection made
						if (sockets[fd - 1].deadlockAck && tcp_rcvd->seq == sockets[fd - 1].nextExpected) {
							sockets[fd - 1].deadlockAck = FALSE;
						}
						//printf("TCP payload: %s\n", tcp_rcvd->payload);
						readInData(fd, tcp_rcvd);
						//printf("read data\n");
						sendTCPPacket(fd, ACK);
						//printf("Sent ACK\n");
						return SUCCESS;
				}
				break;
		}
		return FAIL;	//if all else... FAIL; default return.
	}

	command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
		uint16_t bytesRead = bufflen;
		
		if (fd == 0 || fd > 10 || sockets[fd - 1].state != ESTABLISHED) {	// validating socket
			return 0;
		}
			memcpy(buff, sockets[fd - 1].rcvdBuff, bufflen);
			
		return bytesRead;
	}
	
	command error_t Transport.connect(socket_t fd, socket_addr_t * addr) {
		uint32_t socketId = 0;
		
		//validating socket
		if (fd == 0 || fd > 10 || sockets[fd - 1].state != LISTEN) {	//has to be listening and valid fd
			return FAIL;
		}
		
		//removes old socket in spot
		socketId = (((uint32_t)sockets[fd - 1].src.addr) << 24) | (((uint32_t)sockets[fd - 1].src.port) << 16);
		call SocketMap.remove(socketId);
		
		//puts destination address/port to the socket
		sockets[fd - 1].dest.addr = addr->addr;
		sockets[fd - 1].dest.port = addr->port;
		sockets[fd - 1].type = CLIENT;									
		
		//Sends SYN out
		sendTCPPacket(fd, SYN);
		calcRTO(fd);
		
		//Add to SocketMap
		socketId |= (((uint32_t)addr->addr) << 8) | ((uint32_t)addr->port);
		call SocketMap.insert(socketId, fd);
		
		//Say that the socket (client) is now in a state of SYN_SENT
		sockets[fd - 1].state = SYN_SENT;
		dbg(TRANSPORT_CHANNEL, "SYN sent on node %u via port %u\n", TOS_NODE_ID, sockets[fd-1].src.port);
		
		return SUCCESS;
	}
		
	command error_t Transport.close(socket_t fd) {
		uint32_t socketId = 0;
		
		// validates socket
		if (fd == 0 || fd > 10) {
			return FAIL;
		}
		
		switch(sockets[fd - 1].state) {
			case LISTEN:
				// remove from the SocketMap
				socketId = (((uint32_t)sockets[fd - 1].src.addr << 24)) | (((uint32_t)sockets[fd - 1].src.port) << 16);
				call SocketMap.remove(socketId);
				
				// frees the port slot
				ports[sockets[fd - 1].src.port] = FALSE;
				
				zeroSocket(fd);
				
				// socket is now closed
				sockets[fd - 1].state = CLOSED;
				return SUCCESS;
			case SYN_SENT:
				// remove from the SocketMap
				socketId = (((uint32_t)sockets[fd - 1].src.addr) << 24) | (((uint32_t)sockets[fd - 1].src.port) << 16) | (((uint32_t)sockets[fd - 1].dest.addr) << 8) | ((uint32_t)sockets[fd - 1].dest.port);
				call SocketMap.remove(socketId);
				
				zeroSocket(fd);
				
				// socket is now closed
				sockets[fd - 1].state = CLOSED;
				return SUCCESS;
			case ESTABLISHED:	//dealt with same as SYN_RCVD
			case SYN_RCVD:
				// start FIN sequence
				sendTCPPacket(fd, FIN);
				
				// set to FIN_WAIT_1
				dbg(TRANSPORT_CHANNEL, "Sending FIN. Going to FIN_WAIT_1\n");
				sockets[fd - 1].state = FIN_WAIT_1;
				return SUCCESS;
			case CLOSE_WAIT:
				// continue the FIN sequence
				sendTCPPacket(fd, FIN);
				// set LAST_ACK
				sockets[fd - 1].state = LAST_ACK;
				return SUCCESS;
		}
		return FAIL;
	}
		
	command error_t Transport.release(socket_t fd) {
		uint8_t i;
		
		// validates socket
		if (fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
			return FAIL;
		}
		
		zeroSocket(fd);
		
		return SUCCESS;
	}
	
	command uint8_t Transport.getServerRcvdBuffer(uint8_t fd, uint8_t* buff, uint8_t buffLen) {
		uint8_t bytesRead = 0;
		
		if (sockets[fd-1].rcvdBuff[0] == 0) {
			//printf("here\n");
			return 0;
		}
		memcpy(buff, sockets[fd-1].rcvdBuff, buffLen);
		printf("buff: %s\n", buff);
		bytesRead += buffLen;
		
		return bytesRead;
	}
	
	command error_t Transport.listen(socket_t fd) {	//boolean control variable to check if listening
		// validates socket
		if (fd == 0 || fd > 10) {
			return FAIL;
		}
		
		// if the socket is bound then 
		if (sockets[fd - 1].state == LISTEN) {
			return SUCCESS;
		}
		else {
			return FAIL;
		}
	}

	command uint8_t Transport.getServerNode(uint8_t fd) {
		if (fd <= 0) {
			return 0;
		}
		return sockets[fd - 1].dest.addr;
	}
	
	command uint8_t Transport.getServersNode(uint8_t fd) {
		if (fd <= 0) {
			return 0;
		}
		return sockets[fd - 1].src.addr;
	}
	
}