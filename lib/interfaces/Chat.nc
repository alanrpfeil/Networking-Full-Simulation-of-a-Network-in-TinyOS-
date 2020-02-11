#include "../../includes/packet.h"
#include "../../includes/socket.h"

interface Chat{
   command void startChat(uint8_t src, uint8_t srcPort, uint8_t destPort, uint16_t data, uint8_t* username);
   command void broadcastMsg(uint8_t* message);
   command void whisperMsg(uint8_t* message, uint8_t* username);
   command void printUsers();
   command void startServer();
}
