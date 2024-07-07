import React, { useEffect, useRef, useState } from 'react';
import { useAuth } from '../context/auth-context';
import { useIndexeddb } from '../context/indexeddb-context';

export function Dropdown() {
    const [isOpen, setIsOpen] = useState(false);
    const dropdownRef = useRef<HTMLDivElement>(null);

    const {
        logout,
    } = useAuth();

    const {
        deleteDatabase
    } = useIndexeddb();

    function onToggleDropdown() {
        setIsOpen(!isOpen);
    };

    function onClick() {
        setIsOpen(false);
    };

    function onClickOutside(event: MouseEvent) {
        if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
            setIsOpen(false);
        }
    };

    useEffect(() => {
        if (isOpen) {
            document.addEventListener('mousedown', onClickOutside);
        } else {
            document.removeEventListener('mousedown', onClickOutside);
        }
        return () => {
            document.removeEventListener('mousedown', onClickOutside);
        };
    }, [isOpen]);

    async function onLogOut() {
        setIsOpen(false);

        await logout();

        await deleteDatabase();
    }

    return (
        <div
            className="dropdown"
            ref={dropdownRef}
            >
            <button 
                className="dropdown-toggle mr-2"
                onClick={onToggleDropdown} 
                >
                <i className="fa-solid fa-ellipsis-vertical"></i>
            </button>
            {isOpen && (
                <ul
                    className="dropdown-menu"
                    style={{
                        position: "absolute",
                        top: "calc(100% + 4px)",
                        right: "4px",
                        background: "white",
                        border: "1px solid #ccc",
                        width: "150px",
                        zIndex: "5000",
                    }}
                    >

                    <li onClick={onClick}>
                        Item 1
                    </li>

                    <li onClick={onClick}>
                        Item 2
                    </li>

                    <li onClick={onClick}>
                        Item 3
                    </li>

                    <li
                        onClick={onLogOut}
                        >
                        <i className="w-5 fa-solid fa-right-from-bracket"></i>
                        <span className="hidden sm:inline ml-1">Log out</span>
                    </li>                    
                </ul>
            )}
        </div>
    );
};
