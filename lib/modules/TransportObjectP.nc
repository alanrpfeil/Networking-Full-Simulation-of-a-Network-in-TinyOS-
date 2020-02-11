#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"

//This file includes the facilities that read/write in client/server ports and handles the opening and closing of clients/servers

module TransportObjectP{
	provides interface TransportObject;
	uses interface Random;
	uses interface Transport;
	uses interface Hashmap<uint8_t> as Connections;
	uses interface Timer<TMilli> as myTimer;
	uses interface SimpleSend as Sender;
	uses interface Chat;
}

implementation {

typedef struct server {
	uint8_t fd;					//socket file descriptor
	uint8_t connections[10];	//# of ports/sockets per node
	uint8_t buffer[1024];		//buffer for read/write on a socket
	uint8_t connNum;			//keeps track of how many connections are present
	uint16_t bytesRead;			//R/W via port
	uint16_t bytesWritten;		//R/W via port
} server;

typedef struct client {
	uint8_t fd;					//socket file descriptor
    uint16_t bytesWritten;		//R/W via port
    uint16_t bytesSent;	//R/W via port
    uint16_t ctr;				//counter used for control
    uint16_t transfer;			//transfer bytes to be sent from 0->transfer
    uint8_t buffer[1024];		//buffer for read/write on a socket
} client;

uint8_t numServers = 0; //initializing number of present servers
uint8_t numClients = 0;	//initializing number of present clients
server servers[10];		//Servers in the network
client clients[10];		//Clients in the network

/////////methods for these objects///////////
 void updateServers();	//Look through active sockets and update things accordingly
 void updateClients();	//Look through active sockets and update things accordingly
 uint16_t getServerBufferOccupied(uint8_t idx);
 uint16_t getServerBufferAvailable(uint8_t idx);
 uint16_t getClientBufferOccupied(uint8_t idx);
 uint16_t getClientBufferAvailable(uint8_t idx);
 void nullClient(uint8_t idx);					//NULL client def
 void nullServer(uint8_t idx);					//NULL server def
 uint16_t min(uint16_t a, uint16_t b);			//helper function

 command void TransportObject.startServer(uint8_t port) {
	uint8_t i;
	uint32_t connID;
	socket_addr_t addr; //node associated with socket to bind
	//if more servers than sockets available, cannot start server
	if(numServers >= 10) {
        dbg(TRANSPORT_CHANNEL, "Too many servers; all sockets full\n");
        return;
    }
	for (i = 0; i < 10; i++){
		//do not overwrite a socket that's occupied; goto next available socket:
		if (servers[i].fd != 0) {
			continue;
		}
		else {	//opens available socket
			servers[i].fd = call Transport.socket(); //socket() returns an fd of type socket_t
		}
		//if Transport.socket() returned a valid socket fd...
		if (servers[i].fd > 0) {
			addr.addr = TOS_NODE_ID;	//address = node we're working on
			addr.port = port;
			//binding complete
			if(call Transport.bind(servers[i].fd, &addr) == SUCCESS) {
				connID = ((uint32_t)addr.addr << 24) | ((uint32_t)addr.port << 16);
                call Connections.insert(connID, i+1);
                //connection states initiated to zero...
                servers[i].bytesRead = 0;
                servers[i].bytesWritten = 0;
                servers[i].connNum = 0;
                //We're listening(named) now; start timer for R/W functions
                if(call Transport.listen(servers[i].fd) == SUCCESS && !(call myTimer.isRunning())) {
                    call myTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
                }
				numServers++;	//new server now up and running
			return;
			}
		}
	}
 }
 
 
 command void TransportObject.startClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t data) {
	uint8_t i;
	uint32_t connID;
	socket_addr_t clientAddr;
    socket_addr_t serverAddr;
	
	if(numClients >= 10) {	//checking if ports can support clients
		dbg(TRANSPORT_CHANNEL, "Too many clients. Not enough socket resources\n");
        return;
	} else {
		clientAddr.addr = TOS_NODE_ID;	//THIS node is the client
		clientAddr.port = srcPort;		//our outputting port where we write
		serverAddr.port = destPort;		//port is at dest node's port
		serverAddr.addr = dest;			//server is at destination node
		
		for (i = 0; i < 10; i++) {	//for all ports in socket array
			if (clients[i].fd != 0) { //skip occupied sockets
				continue;
			}
			//else open a new socket at available port:
			clients[i].fd = call Transport.socket();	//get socket file descriptor
			if (clients[i].fd == 0) {
				dbg(TRANSPORT_CHANNEL, "No socket fd available; Most likely all occupied.");
                return;
			}	//now bind...
			if(call Transport.bind(clients[i].fd, &clientAddr) == FAIL) {
                dbg(TRANSPORT_CHANNEL, "Client failed to bind.\n");
                return;
            }
			connID = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16);	//used for connections map
			call Connections.insert(connID, i+1);
			//start next part of the 3-way handshake; connection attempt
			if(call Transport.connect(clients[i].fd, &serverAddr) == FAIL) {
                dbg(TRANSPORT_CHANNEL, "Failed to Connect to the Server.\n");
                return;
            }
			
			//updating old connection...
			call Connections.remove(connID);
			connID = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16) | ((uint32_t)dest << 16) | ((uint32_t)destPort << 16);	//concatenated
			call Connections.insert(connID, i+1);
			
			//connection states initialized now since connection presumably complete:
			clients[i].transfer = data;
            clients[i].ctr = 0;
            clients[i].bytesWritten = 0;
            clients[i].bytesSent = 0;
			
			//start timer for R/W functions if not already started up
			if(!(call myTimer.isRunning())) {
				call myTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
			}
			numClients++;
			
			return;
		}
	
	}
 }
 
 command error_t TransportObject.copyChatRoomUsers(uint8_t dest, uint8_t* username, bool used, uint8_t srcPort, uint8_t destPort){
	uint8_t buffLength;
	uint32_t socketID, connID;
	
	buffLength = 8;
	connID = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16) | ((uint32_t)dest << 16) | ((uint32_t)destPort << 16);
	socketID = call Connections.get(connID);	//pull out right connection in hashmap
	if (socketID == 0) {
		dbg(TRANSPORT_CHANNEL, "DNE Chat Client\n");
        return;
	}
	
	memcpy(clients[socketID - 1].buffer, username, buffLength);
	
	//printf("buffLength: %u\n", buffLength);
	//printf("%s\n", clients[socketID-1].buffer);
 
	clients[socketID - 1].bytesWritten = buffLength;
	
	//call Transport.sendWhisper(UPD);
	
	return 1;
 }
 
 command void TransportObject.closeClient(uint8_t srcPort, uint8_t destPort, uint8_t dest) {
	uint32_t socketID, connID;
	//go to index of socket specified
	connID = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16) | ((uint32_t)dest << 16) | ((uint32_t)destPort << 16);
	socketID = call Connections.get(connID);	//pull out right connection in hashmap
	if (socketID == 0) {
		dbg(TRANSPORT_CHANNEL, "DNE Client\n");
        return;
	}
	//closing socket now that correct connection found...
	dbg(TRANSPORT_CHANNEL, "Attempting to Close Client (Node): %u With Port: %u\n", TOS_NODE_ID, srcPort);
	call Transport.close(clients[socketID-1].fd);
	//we now nullify the socket_t previously created
	nullClient(socketID - 1);
	numClients--; //one less Client now
 }
 
 command void TransportObject.whisperMsg(uint8_t src, uint8_t dest, uint8_t srcPort, uint8_t destPort, uint8_t* message) {
	uint8_t buffLength = 16;
	uint32_t socketID, connID;
	connID = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16) | ((uint32_t)dest << 16) | ((uint32_t)destPort << 16);
	socketID = call Connections.get(connID);	//pull out right connection in hashmap
	if (socketID == 0) {
		dbg(TRANSPORT_CHANNEL, "DNE Client\n");
        return;
	}
	
	memcpy(clients[socketID - 1].buffer, message, buffLength);
	
	printf("buffLength: %u\n", buffLength);
	printf("%s\n", clients[socketID-1].buffer);
 
	clients[socketID - 1].bytesWritten = buffLength;
	
	//Transport.sendWhisper();
 
 }
 
 command uint8_t TransportObject.copyRcvdBuffer(uint8_t serverNode, uint8_t* buff, uint8_t buffLen) {
	uint8_t i;
	uint8_t bytesCopied = 0;
	for (i = 0; i < 10; i++) {
		if ((call Transport.getServerNode(servers[i].fd) == serverNode) && (servers[i].buffer[0] != 0)) {
			memcpy(buff, servers[i].buffer, buffLen);
			bytesCopied = buffLen;
		}
	}
	return bytesCopied;
 }
 
 event void myTimer.fired() {
	//whenever timer is fired we need to read and write stuff on the socket/port from appropiate open servers/clients
	updateServers();
	updateClients();
 }
 
 void updateServers() {
	uint8_t i, j, Bytes, new_fd;	//B is capital for Bytes vs. bits
	//uint16_t len;
	//uint8_t* data;
	bool isRead = FALSE;
	Bytes = 0;
	
	for (i = 0; i < numServers; i++) {	//for all existing servers...
		if(servers[i].fd == 0) {
			continue; 	//skip empty sockets if any
		}
		//printf("fd: %u\n", servers[i].fd);
		//accepting new connections if any attempts exist
		new_fd = call Transport.accept(servers[i].fd);	//accept their fd
		//printf("newfd: %u\n", new_fd);
		if(new_fd > 0) {	//if valid fd gotten
                if(servers[i].connNum < 9) {			//if room for +1 fd on port...
                    servers[i].connections[servers[i].connNum++] = new_fd;	//add connection count
					dbg(TRANSPORT_CHANNEL, "Added to connections\n");
            }
        }
		
		//reading current connections...
		for (j = 0; j < servers[i].connNum; j++) {
			if(servers[i].connections[j] != 0) {	//as long as connection exists here...
				//printf("getServerBufferAvailable: %u\n", getServerBufferAvailable(i));
				//servers[i].buffer = call Transport.getServerRcvdBuffer(servers[i].fd);
				if(getServerBufferOccupied(i) > 0) {
                    //len = min((1024 - servers[i].bytesWritten), getServerBufferOccupied(i));
                    Bytes += call Transport.read(servers[i].connections[j], &servers[i].buffer[servers[i].bytesWritten], getServerBufferOccupied(i));
                    servers[i].bytesWritten += Bytes;
					//printf("byteswritten to server: %u\n", servers[i].bytesWritten);
					//printf("String now: %s\n", servers[i].buffer);
					isRead = TRUE;
                    if(servers[i].bytesWritten == getServerBufferOccupied(i)) {	//making sure all Bytes written
						servers[i].bytesWritten = 0;
                    }
                }

				//servers[i].bytesWritten = call Transport.getServerRcvdBuffer(servers[i].fd, servers[i].buffer, 16);
			}
		}
		/*
		while(getServerBufferOccupied(i) >= 2) {
			if(!isRead) {	//if data not read already read...
				dbg(TRANSPORT_CHANNEL, "Reading Data at %u: ", servers[i].bytesRead);
                isRead = TRUE;
			}
			if(servers[i].bytesRead == 1024) {	//if everything read...
				servers[i].bytesRead = 0; //reset
			}
			//printf("String now: %s\n", servers[i].buffer);
			//data = (((uint16_t)servers[i].buffer[servers[i].bytesRead+1]) << 8) | (uint16_t)servers[i].buffer[servers[i].bytesRead];
			
			data = servers[i].buffer;
			//printf("%s\n", data);
            servers[i].bytesRead += 2;
		}
		*/
		if(isRead) {	//formatting if something was read; neatness
			printf("\n");
			servers[i].bytesRead = 0;
		}
		
	}
 }
 
 
 void updateClients() {
	uint8_t i, j;
	uint16_t bytesSent, bytesToSend, bytesStolen;
	uint8_t flags;
	
	for (i = 0; i < 10; i++) {
		if(clients[i].fd == 0) {
			continue;	//skipping empty sockets...
		}
		if (i == 0) {
			//printf("bytesWritten: %u bytesSent: %u, getClientBufferOccupied: %u, transfer: %u\n", clients[0].bytesWritten, clients[0].bytesSent, getClientBufferOccupied(0), clients[0].transfer);	//debugging
		}
		clients[i].bytesSent = 0;
		//writing...
		
		for (j = 0; j < 10; j++) {
			//printf("%u, %u\n", call Transport.getServerNode(clients[i].fd), call Transport.getServersNode(servers[j].fd));
			if (call Transport.getServerNode(clients[i].fd) == 8) {
				//printf("%u\n", getServerBufferOccupied(j));
				if (getServerBufferOccupied(j) > 0) {
					call Transport.receiveMessage(servers[j].buffer);
				}
			}
		}
		
		/*
		while(getClientBufferAvailable(i) > 0 && clients[i].ctr < clients[i].transfer) { //while bytes can be read from buffer...
			if(clients[i].bytesWritten == 1024) {	//if valid buffered bytes
                clients[i].bytesWritten = 0;
            }
            if((clients[i].bytesWritten & 1) == 0) {
                clients[i].buffer[clients[i].bytesWritten] = clients[i].ctr & 0xFF;	//copying byte
            } else {
                clients[i].buffer[clients[i].bytesWritten] = clients[i].ctr >> 8;
                clients[i].ctr++;
            }
            clients[i].bytesWritten++;
		}
		*/
		//writing to socket now
		if(getClientBufferOccupied(i) > 0) {
		
			if (clients[i].bytesWritten == 8) {
				flags = UPD;
			} else {
				flags = DATA;
			}
		
            bytesToSend = min((1024 - clients[i].bytesSent), (clients[i].bytesWritten - clients[i].bytesSent));
			//printf("bytesToSend: %u\n", bytesToSend);
            bytesSent = call Transport.write(clients[i].fd, &clients[i].buffer[0], clients[i].bytesWritten);
			//printf("bytesSent: %u\n", bytesSent);
            //clients[i].bytesSent += bytesSent;
			for (j = 0; j < clients[i].bytesWritten; j++) {
				clients[i].buffer[j] = 0;
			}
			clients[i].bytesWritten -= bytesSent;
			call Transport.sendWhisper(clients[i].fd, flags);
        }
        if(clients[i].bytesSent >= 1024) {
			clients[i].bytesSent = 0;
		}
	}
 }
 
 //A function to make a server NULL
 void nullServer(uint8_t serverID) {
	uint8_t i;
    servers[serverID].fd = 0;
    servers[serverID].bytesRead = 0;
    servers[serverID].bytesWritten = 0;
    servers[serverID].connNum = 0;
    for(i = 0; i < 9; i++) {		//9 = number of ports - 1
        servers[serverID].connections[i] = 0;
    }
 }
 //A function to make a client NULL
 void nullClient(uint8_t clientID) {
	clients[clientID].fd = 0;
	clients[clientID].ctr = 0;
    clients[clientID].transfer = 0;
    clients[clientID].bytesWritten = 0;
    clients[clientID].bytesSent = 0;
 }
 
 
 uint16_t getServerBufferOccupied(uint8_t socketID) {
	if (servers[socketID].bytesRead == servers[socketID].bytesWritten) {		//everything written is read or nothing to R/W
        return 0;
    } else if (servers[socketID].bytesRead < servers[socketID].bytesWritten) {	//stuff needs to be read
        return servers[socketID].bytesWritten - servers[socketID].bytesRead;	//remainder bytes to read
    } else {
        return (1024 - servers[socketID].bytesRead) + servers[socketID].bytesWritten;
    }
 }
 
  uint16_t getServerBufferAvailable(uint8_t socketID) {
   return 1024 - getServerBufferOccupied(socketID) - 1;
  }
 
  uint16_t getClientBufferOccupied(uint8_t socketID) {
    if (clients[socketID].bytesSent == clients[socketID].bytesWritten) {		//write bytes already sent out; nothing in buffer
        return 0;
    } else if (clients[socketID].bytesSent < clients[socketID].bytesWritten) {
        return clients[socketID].bytesWritten - clients[socketID].bytesSent;	//stuff still needs to be sent
    } else {
        return (1024 - clients[socketID].bytesSent) + clients[socketID].bytesWritten;
    }
  }
  
  uint16_t getClientBufferAvailable(uint8_t socketID) {
    return 1024 - getClientBufferOccupied(socketID) - 1;	//returns the space remaining in the buffer
  }
  
 //min helper function//
  uint16_t min(uint16_t a, uint16_t b) {
    if(a <= b) {
      return a;
    } else {
      return b;
	}
  }
 
}