#ifndef __SOCKET_H__
#define __SOCKET_H__

enum{
    MAX_NUM_OF_SOCKETS = 10,
    ROOT_SOCKET_ADDR = 255,
    ROOT_SOCKET_PORT = 255,
    SOCKET_BUFFER_SIZE = 128,
};

enum TYPE{
	SERVER,
	CLIENT,
};

enum socket_state{
    CLOSED,
    LISTEN,
    ESTABLISHED,
	NAMED,
    SYN_SENT,
    SYN_RCVD,
	FIN_WAIT_1,
	FIN_WAIT_2,
	CLOSING,
	CLOSE_WAIT,
	TIME_WAIT,
	LAST_ACK,
};

enum cong_strat {
	SLOW_START,
	AIMD,
};

typedef nx_uint8_t nx_socket_port_t;
typedef uint8_t socket_port_t;

// socket_addr_t is a simplified version of an IP connection.
typedef nx_struct socket_addr_t{
    nx_socket_port_t port;
    nx_uint16_t addr;
}socket_addr_t;

//struct to help with duplicated ACKs with congestion control
typedef struct duplicated_ack{
	uint16_t seq;	//sequence number affiliation
	uint16_t count;	//number of dupes rcvd
}duplicated_ack;

// File descripter id. Each id is associated with a socket_store_t
typedef uint8_t socket_t;

// State of a socket. 
typedef struct socket_store_t{
    uint8_t flag;
    enum socket_state state;
	enum TYPE type;
	
    //socket_port_t src;	before change
	socket_addr_t src;		//USED
    socket_addr_t dest;
	
	// added variables (USED)
	uint8_t connectionQueue[SOCKET_BUFFER_SIZE];	
	bool deadlockAck;
	uint8_t advertisedWindow;

    // This is the sender portion.
    uint8_t sendBuff[SOCKET_BUFFER_SIZE];
    uint8_t lastWritten;
    uint8_t lastAck;
    uint8_t lastSent;

    // This is the receiver portion
    uint8_t rcvdBuff[SOCKET_BUFFER_SIZE];
    uint8_t lastRead;			//USED
    uint8_t lastRcvd;			//USED
    uint8_t nextExpected;		//USED

    uint16_t RTT;
    uint8_t effectiveWindow;
	
	//congestion handling and window
	uint16_t ack;
	duplicated_ack duplicateAck;
	
	uint8_t ssthresh;	//slow start threshold - Where AIMD takes over
	uint8_t cwnd; 		//congestion window
	uint8_t cwndRemainder;
	enum cong_strat cwndStrategy;
	
	//RTT calculation stuff
	uint32_t RTO;
	uint32_t RTX;
	uint32_t RTT_VAR;
	uint16_t RTT_SEQ;
	bool IS_VALID_RTT;
	
}socket_store_t;

#endif
