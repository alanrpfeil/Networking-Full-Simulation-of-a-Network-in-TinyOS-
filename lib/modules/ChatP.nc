#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"


#define MAX_USERS 20
#define MAX_USERNAME 25
#define MAX_MESSAGE 8

module ChatP{
	provides interface Chat;
	uses interface Random;
	uses interface Transport;
	uses interface Hashmap<uint8_t> as Connections;
	uses interface Timer<TMilli> as myTimer;
	uses interface SimpleSend as Sender;
	uses interface TransportObject;
}

implementation {

enum{
	whisper=0,
	broadcast=1,
};

typedef struct chatroom{
	//uint8_t users[MAX_USERS][MAX_USERNAME];
	uint8_t* users[MAX_USERS];
	uint8_t userBuffs[MAX_USERS][MAX_MESSAGE];	//could use to store multiple messages like a queue...
	bool used[MAX_USERS];
	uint8_t buff[MAX_MESSAGE];
	uint8_t chatServer;
	uint8_t srcPorts[MAX_USERS];
	uint8_t destPorts[MAX_USERS];
	uint8_t bytesWritten;
	uint8_t broadcastType;	//broadcast type "queue" of sorts
	uint8_t whisperTo;
	bool started;
} chatroom;

chatroom lobby;

void nullBuff(uint8_t index) {
	uint8_t i;

	for (i = 0; i < MAX_MESSAGE; i++) {
		lobby.userBuffs[index][i] = 0;
	}
}

command void Chat.startServer() {
	lobby.chatServer = TOS_NODE_ID;
	lobby.started = 1;
	
	dbg(APPLICATION_CHANNEL, "This Server is Now the Chat Room!\n");
	
	if (!(call myTimer.isRunning())) {
        call myTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
    }
	
}

void distributeMessage(){
	uint8_t i;
	
	if (lobby.broadcastType == broadcast) {
		for (i = 0; i < MAX_USERS; i++) {
			if (lobby.used[i] == 1) {
				memcpy(lobby.userBuffs[i], lobby.buff, MAX_MESSAGE);
			}
		}
	} else {	//whisper type
		memcpy(lobby.userBuffs[lobby.whisperTo-1], lobby.buff, MAX_MESSAGE);
	}
}

event void myTimer.fired() {
	uint8_t i, src;
	bool isCopied;
	uint8_t username[6];
	isCopied = 0;
	
	//dbg(APPLICATION_CHANNEL, "AT THIS NODE\n");
	//checking for other clients connected to the server you're on...
	//call TransportObject.copyChatRoomUsers(lobby.chatServer, lobby.users, lobby.used, lobby.srcPorts, lobby.destPorts);
	
	//copy recieved buffer in server over to chatroom's buffer
	lobby.bytesWritten = call TransportObject.copyRcvdBuffer(lobby.chatServer, lobby.buff, MAX_MESSAGE);
	
	if (lobby.bytesWritten == MAX_MESSAGE) {
		lobby.bytesWritten = 0;	//wrote everything to chatroom buffer
		isCopied = 1;
	}
	if (isCopied == 1) {
		
		printf("Node %u's buff: %s\n", TOS_NODE_ID, lobby.buff);
	
		if ((lobby.buff[1] == 47) && (lobby.buff[2] == 110)) {	//47 == '\', //110 == 'n'
			printf("Entering\n");
		
			username[0] = lobby.buff[3];
			username[1] = lobby.buff[4];
			username[2] = lobby.buff[5];
			username[3] = lobby.buff[6];
			username[4] = lobby.buff[7];
			
			src = lobby.buff[0];
			
			lobby.used[src] = 1;
			lobby.users[src] = username;
			
			return;
		}
		/*
		if ((lobby.buff[0] == '\') && (lobby.buff[1] == 'n')) {
			
		}
	
		if ((lobby.buff[0] == '\') && (lobby.buff[1] == 'n')) {
			
		}
		*/
		distributeMessage();	//handles if whisper or broadcast
	
		for (i = 0; i < MAX_USERS; i++) {
			if (lobby.used[i] == 1) {
				if (lobby.userBuffs[i][0] != 0) {
					dbg(APPLICATION_CHANNEL, "User %s Received the Message: %s\n", lobby.users[i], lobby.userBuffs[i]);
					nullBuff(i);	//reset buffer for user since recent message 'popped' from it
				}
			}
		}
	}
	
}

 //requires a testServer is called before this...
command void Chat.startChat(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t data, uint8_t* username) {
	uint8_t i, c, d;
	
	if (lobby.started == 0) {
		lobby.chatServer = dest;
		lobby.started = 1;
	}
	
	if (lobby.used[TOS_NODE_ID-1] == 0) {
		lobby.users[TOS_NODE_ID-1] = username;
		lobby.srcPorts[TOS_NODE_ID-1] = srcPort;
		lobby.destPorts[TOS_NODE_ID-1] = destPort;
		lobby.used[TOS_NODE_ID-1] = 1;
	} else {
		dbg(APPLICATION_CHANNEL, "User Already Exists at This Address.");
	}

	call TransportObject.startClient(lobby.chatServer, srcPort, destPort, data);
	
	dbg(APPLICATION_CHANNEL, "Welcome User '%s'. You Are Now Logged Into the Chat Room!\n", lobby.users[TOS_NODE_ID-1]);
	
	if (!(call myTimer.isRunning())) {
        call myTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
    }
	
	if (lobby.used[TOS_NODE_ID-1] == 1) {
		printf("called\n");
		lobby.started = call TransportObject.copyChatRoomUsers(dest, username, 1, srcPort, destPort);
		
	}
	
	return;
}
 
command void Chat.whisperMsg(uint8_t* message, uint8_t* username) {
	uint8_t i, dest, src, srcPort, destPort;
	
	for (i = 0; i < MAX_USERS; i++) {
		if (lobby.users[i] == username) {
			lobby.whisperTo = i;
			break;
		}
	}
	
	for (i = 0; i < MAX_USERS; i++) {
		if ((lobby.used[i]) == 1 && (lobby.users[i] != username)) {
			srcPort = lobby.srcPorts[i];	//sending from anonymous client????
			src = i+1;
			break;
		}
	}
	
	dest = lobby.chatServer;
	destPort = lobby.destPorts[lobby.chatServer-1];
	
	lobby.broadcastType = whisper;
	call TransportObject.whisperMsg(src, dest, srcPort, destPort, message);
	
	return;
}
 
command void Chat.broadcastMsg(uint8_t* message) {
	uint8_t src, dest, destPort, srcPort, i;
	
	lobby.broadcastType = broadcast;
	
	for (i = 0; i < MAX_USERS; i++) {
		if ((lobby.used[i]) == 1) {
			srcPort = lobby.srcPorts[i];	//sending from anonymous client????
			src = i+1;
			destPort = lobby.destPorts[i];
			dest = lobby.chatServer;
			break;
		}
	}
	
	call TransportObject.whisperMsg(TOS_NODE_ID, dest, srcPort, destPort, message);
	
	return;
}
 
command void Chat.printUsers() {
	uint8_t i;
	
	for (i = 0; i < MAX_USERS; i++) {
		if (lobby.used[i] == 1) {
			dbg(APPLICATION_CHANNEL, "User %u: %s\n", i, lobby.users[i]);
		}
	}
	
	return;
}
 
}