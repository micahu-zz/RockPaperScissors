pragma solidity ^0.4.23; // solhint-disable-line

import "./SafeMath.sol";
import "zeppelin-solidity/contracts/ownership/Ownable.sol";


/// @title RockPaperScissors Smart Contract
/// @author Micah Uhrlass
/// @notice Hosts Rock-Paper-Scissors matches for two
contract RockPaperScissors is Ownable {
    using SafeMath for uint256;

    uint256 matchExpiry = 200;
    uint256 roundExpiry = 25;
    address queuedPlayer;
    bytes32 Rock = keccak256("Rock");
    bytes32 Paper = keccak256("Paper");
    bytes32 Scissors = keccak256("Scissors");

    mapping(address => Player) public players;
    mapping(bytes32 => Match) public matches;

    struct Match {
        uint256 matchDeadline;
        uint256 roundDeadline;
        address player1;
        address player2;
    }

    struct Player {
        uint256 balance;
        uint256 wager;
        bytes32 shot;
        bytes32 verifiedShot;
        bytes32 activeMatch;
    }

    event PlayerEnrolled(address playerAddr, uint256 wager);
    event MatchCreated(address player1, address player2, uint256 blockDeadline);
    event Tie(address player1, address player2, bytes32 sharedShot);
    event Reward(address winner, uint256 winnings);
    event WithdrawalMade(address by, uint256 amount);
    
    ///
    /// PUBLIC FUNCTIONS
    /// 
    function generateHash(string shot, string randomStr, address playerAddr) public returns (bytes32) {
        return keccak256(abi.encodePacked(shot, randomStr, playerAddr));
    }

    function enroll(uint256 fromExistingBalance) public payable {
        require(msg.value > 0, "msg.value equals 0");
        
        Player storage p = players[msg.sender];
        require(p.activeMatch[0] == 0, "you are already in bx match or in queue for the next match");
        
        p.balance = players[msg.sender].balance.sub(fromExistingBalance);
        p.wager = msg.value.add(fromExistingBalance);
        
        if (queuedPlayer == address(0)) queuedPlayer = msg.sender;
        else createMatch(msg.sender);

        emit PlayerEnrolled(msg.sender, (msg.value.add(fromExistingBalance)));
    }

    function shoot(bytes32 secretShot) public {
        Player storage p = players[msg.sender];
        require(p.shot[0] == 0, "shot already submitted for current round");
        p.shot = secretShot;
    }

    function revealShot(string shot, string randomStr) public {
        bytes32 shotHash = keccak256(shot);
        require(shotHash == Rock || shotHash == Paper || shotHash == Scissors, "invalid shot");
        bytes32 expectedHash = generateHash(shot, randomStr, msg.sender);
        
        Player storage p = players[msg.sender];
        require(expectedHash == p.shot, "this does not match your initial submission. please try again.");
        p.verifiedShot = shotHash;
        delete p.shot;

        // start round expiry countdown
        Match storage m = matches[p.activeMatch];
        m.roundDeadline = block.number.add(roundExpiry);
        evaluateShots(msg.sender);
    }

    function withdraw() public {
        Player storage p = players[msg.sender];
        require(p.activeMatch[0] != 0, "reward has already been paid out, match no longer active");
        require(p.verifiedShot[0] != 0, "you have not verified your shot yet");
        
        Match memory m = matches[p.activeMatch];
        require(m.roundDeadline >= block.number, "round deadline not yet met");
        
        // reward and send balance
        if (msg.sender == m.player1) reward(msg.sender, m.player2);
        else reward(msg.sender, m.player1);

        require(p.balance > 0, "you've won the match by default but have nothing to withdraw");
        uint256 balance = p.balance;
        p.balance = 0;
        emit WithdrawalMade(msg.sender, balance);
        msg.sender.transfer(balance);
    }

    function withdraw(address player1, address player2) public onlyOwner {
        bytes32 matchId = keccak256(toConcatString(player1, player2));
        Match storage m = matches[matchId];
        require(m.matchDeadline >= block.number, "match deadline not yet met");
        Player storage p1 = players[m.player1];
        Player storage p2 = players[m.player2];

        // collect wagers from both players
        uint256 allowance = p1.wager.add(p2.wager);
        require(allowance > 0, "nothing to withdraw, allowance equals 0");
        delete p1.wager;
        delete p2.wager;

        // delete match
        delete matches[matchId];
        
        // deactivate players
        delete p1.verifiedShot;
        delete p2.verifiedShot;
        delete p1.activeMatch;
        delete p2.activeMatch;
        
        emit WithdrawalMade(msg.sender, allowance);
        msg.sender.transfer(allowance);
    }

    ///
    /// INTERNAL FUNCTIONS
    /// 
    function createMatch(address player2) internal {
        bytes32 matchId = keccak256(toConcatString(queuedPlayer, player2));
        Match storage m = matches[matchId];
        Player storage p1 = players[queuedPlayer];
        Player storage p2 = players[player2];
        p1.activeMatch = matchId;
        p2.activeMatch = matchId;

        // start match expiry countdown
        m.matchDeadline = block.number.add(matchExpiry);
        
        emit MatchCreated(queuedPlayer, player2, (block.number.add(matchExpiry)));
    }
    
    function evaluateShots(address playerAddr) internal {
        Player storage p = players[msg.sender];
        require(p.verifiedShot[0] != 0, "player missing verified shot");
        
        address oppAddr;
        Match memory m = matches[p.activeMatch];
        if (playerAddr == m.player1) oppAddr = m.player2;
        else oppAddr = m.player1;

        Player storage opp = players[oppAddr];
        require(opp.verifiedShot[0] != 0, "opponent missing verified shot");
        
        bytes32 pShot = p.verifiedShot;
        bytes32 oppShot = opp.verifiedShot;

        if (pShot == oppShot) {
            delete p.verifiedShot;
            delete opp.verifiedShot;
            emit Tie(playerAddr, oppAddr, pShot);
        }
        else {
            if (pShot == Rock && oppShot == Paper) {reward(oppAddr, playerAddr);}
            else if (pShot == Rock && oppShot == Scissors) {reward(playerAddr, oppAddr);}
            else if (pShot == Paper && oppShot == Rock) {reward(playerAddr, oppAddr);}
            else if (pShot == Paper && oppShot == Scissors) {reward(oppAddr, playerAddr);}
            else if (pShot == Scissors && oppShot == Rock) {reward(oppAddr, playerAddr);}
            else if (pShot == Scissors && oppShot == Paper) {reward(playerAddr, oppAddr);}
        }
    }

    function reward(address winner, address loser) internal {
        uint256 award = 0;
        Player storage w = players[winner];
        Player storage l = players[loser];

        // set award as the lower of the two wagers
        if (w.wager >= l.wager) {award = w.wager;}
        else (award = l.wager);

        // move award amount from both players' wagers to winner's balance
        w.balance = w.balance.add(w.wager.add(award));
        delete w.wager;
        delete l.wager;

        // delete match
        delete matches[w.activeMatch];
        
        // deactivate players
        delete w.verifiedShot;
        delete l.verifiedShot;
        delete w.activeMatch;
        delete l.activeMatch;
        
        emit Reward(winner, award);
    }
    
    function toConcatString(address x, address y) internal pure returns (string) {
        // instantiate byte arrays
        bytes memory bx = new bytes(20);
        bytes memory by = new bytes(20);
        bytes memory bxy = new bytes(bx.length.add(by.length));
        
        // create byte arrays from addresses
        for (uint i = 0; i < 20; i++) {
            bx[i] = byte(uint8(uint(x) / (2**(8*(19 - i)))));
            by[i] = byte(uint8(uint(y) / (2**(8*(19 - i)))));
        }
        
        // concatenate by pushing both to byte array
        uint k = 0;
        for (i = 0; i < bx.length; i++) bxy[k++] = bx[i];        
        for (i = 0; i < by.length; i++) bxy[k++] = by[i];

        // cast concatentated byte array to string
        return string(bxy);
    }
}